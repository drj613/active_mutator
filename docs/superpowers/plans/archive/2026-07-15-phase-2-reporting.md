# Phase 2 — Reporting Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Stryker mutation-testing-report-schema v2 reporter (#17), per-operator equivalent-rate metric (#20), and GitHub Actions annotation reporter (#19); resolve #13/#14 as decisions.

**Architecture:** Reporters live in `lib/active_mutator/reporter/` and implement `on_result(result)` + `summary(results, invalid_count:)`. `Runner#build_reporter` selects by `config.format`. Three additions: (1) `Edit` gains an `operator` name filled by `Operators::Base#edit` — the single construction point — giving every mutation operator identity; (2) `Reporter::StrykerJson` writes `.active_mutator/mutation-report.json` atomically, with `coveredBy` filled from the coverage map (injected by Runner after the baseline builds, via duck-typed `coverage_map=`); (3) `Reporter::Github` projects survivors into `::warning` annotation lines using a shared byte-range→line/column helper.

**Tech Stack:** Ruby 3.2+, RSpec, Prism byte-range edits, `AtomicFile` (existing flock+rename writer), mutation-testing-report-schema v2.

**Standing protocol (from the roadmap, applies to every task):**
- TDD: red → green → commit. `bundle exec rspec` green before every commit.
- Self-mutation gate at end of each task: `bundle exec exe/active_mutator lib --changed` → exit 0 (kill survivors with tests; do NOT touch `.active_mutator_accepted.json` — the ledger is controller-only, see issue #24).
- NOTE: positional args are directories (`lib`), never file paths (issue #23).
- Dogfood gate at phase end on payint (`~/Documents/enovis/payint`, branch `active-mutator-poc`); log rows in `docs/dogfood-log.md`.

---

## File map

| File | Role |
|---|---|
| `lib/active_mutator/edit.rb` | add `operator` member (default `"Unknown"`) |
| `lib/active_mutator/operators/base.rb` | `#edit` helper fills `operator` from class name |
| `lib/active_mutator/source_location.rb` (new) | byte range + source → 1-based start/end line/column |
| `lib/active_mutator/reporter/operator_stats.rb` (new) | per-operator counts + equivalent rate (#20) |
| `lib/active_mutator/reporter/stryker_json.rb` (new) | schema-v2 report writer (#17) |
| `lib/active_mutator/reporter/github.rb` (new) | `::warning` annotations (#19) |
| `lib/active_mutator/reporter/json.rb`, `terminal.rb` | surface operator stats in summaries (#20) |
| `lib/active_mutator/runner.rb` | `build_reporter` cases; inject coverage map |
| `lib/active_mutator/cli.rb` | `--format` allowlist `terminal json stryker-json github` |
| `lib/active_mutator.rb` | requires for new files |

---

### Task 1: Operator identity on Edit

**Files:**
- Modify: `lib/active_mutator/edit.rb`
- Modify: `lib/active_mutator/operators/base.rb`
- Test: `spec/active_mutator/operators_spec.rb` (create if absent; check for an existing operator spec first and add there)

Every mutation must know which operator produced it (`mutatorName` in Stryker, grouping key for #20). Single construction point is `Operators::Base#edit`, so the change is two lines plus a default so existing direct `Edit.new(range:, replacement:, description:)` call sites (specs) keep working.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/active_mutator/operators_spec.rb
require "spec_helper"

RSpec.describe ActiveMutator::Operators do
  it "stamps every edit with its operator's class name" do
    node = Prism.parse("x.map { |i| i }").value.statements.body.first
    edits = ActiveMutator::Operators::CallSwap.new.edits(node)
    expect(edits).not_to be_empty
    expect(edits).to all(have_attributes(operator: "CallSwap"))
  end

  it "defaults operator to Unknown when constructed directly" do
    edit = ActiveMutator::Edit.new(range: 0...1, replacement: "y", description: "d")
    expect(edit.operator).to eq("Unknown")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/active_mutator/operators_spec.rb`
Expected: FAIL — `unknown keyword` / `missing attribute operator`.

- [ ] **Step 3: Implement**

`lib/active_mutator/edit.rb`:

```ruby
module ActiveMutator
  # A single mutation as a text edit: replace `range` (exclusive byte Range)
  # in the original source with `replacement`. `operator` is the producing
  # operator's demodulized class name ("CallSwap"), "Unknown" outside the
  # operator pipeline.
  Edit = Data.define(:range, :replacement, :description, :operator) do
    def initialize(range:, replacement:, description:, operator: "Unknown")
      super
    end
  end
end
```

`lib/active_mutator/operators/base.rb`, replace the private `edit` helper:

```ruby
      def edit(range, replacement, description)
        Edit.new(range: range, replacement: replacement, description: description,
                 operator: self.class.name.split("::").last)
      end
```

- [ ] **Step 4: Full suite**

Run: `bundle exec rspec`
Expected: PASS. If any spec constructs `Edit` positionally (not kwargs), convert it to kwargs.

- [ ] **Step 5: Self-mutation gate**

Run: `bundle exec exe/active_mutator lib --changed`
Expected: exit 0. Likely survivor: `split("::").last` → `.first` — the "CallSwap" assertion in Step 1 kills it (asserts demodulized name, not `ActiveMutator::...`).

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/edit.rb lib/active_mutator/operators/base.rb spec/active_mutator/operators_spec.rb
git commit -m "feat: stamp edits with producing operator name

Foundation for Stryker mutatorName (#17) and per-operator stats (#20)."
```

---

### Task 2: SourceLocation helper

**Files:**
- Create: `lib/active_mutator/source_location.rb`
- Modify: `lib/active_mutator.rb` (add `require_relative "active_mutator/source_location"` alongside the other requires)
- Test: `spec/active_mutator/source_location_spec.rb`

Stryker locations and GH annotations both need 1-based line/column from an exclusive byte range. One helper, two consumers.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/active_mutator/source_location_spec.rb
require "spec_helper"

RSpec.describe ActiveMutator::SourceLocation do
  let(:source) { "def a\n  x > 1\nend\n" }

  it "locates a mid-file span with 1-based line and column" do
    # bytes 10...11 is ">" on line 2, column 5
    loc = described_class.locate(source, 10...11)
    expect(loc).to eq(start: { line: 2, column: 5 }, end: { line: 2, column: 6 })
  end

  it "locates a span at byte 0 as line 1 column 1" do
    loc = described_class.locate(source, 0...3)
    expect(loc[:start]).to eq(line: 1, column: 1)
  end

  it "handles a span crossing a newline" do
    # "1\nend" — starts line 2, ends line 3
    loc = described_class.locate(source, 12...17)
    expect(loc[:start][:line]).to eq(2)
    expect(loc[:end][:line]).to eq(3)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/active_mutator/source_location_spec.rb`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Implement**

```ruby
# lib/active_mutator/source_location.rb
module ActiveMutator
  # 1-based line/column (never 0 — the Stryker schema rejects 0) for an
  # exclusive byte range within a source string.
  module SourceLocation
    def self.locate(source, byte_range)
      {
        start: position(source, byte_range.begin),
        end: position(source, byte_range.end)
      }
    end

    def self.position(source, offset)
      prefix = source.byteslice(0, offset)
      last_newline = prefix.rindex("\n")
      {
        line: prefix.count("\n") + 1,
        column: offset - (last_newline ? last_newline + 1 : 0) + 1
      }
    end
  end
end
```

Note: `column` here is computed on the byteslice string; `rindex` returns a character index. Fixture sources in this repo are ASCII so char==byte; that's fine — the schema only requires positive integers, and off-by-multibyte is cosmetic. Do not gold-plate.

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/source_location_spec.rb`
Expected: PASS. Then `bundle exec rspec` → PASS.

- [ ] **Step 5: Self-mutation gate**

Run: `bundle exec exe/active_mutator lib --changed`
Expected: exit 0. Prime survivors: `+ 1` deletions on line/column — the exact-value assertions in Step 1 kill them.

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/source_location.rb lib/active_mutator.rb spec/active_mutator/source_location_spec.rb
git commit -m "feat: SourceLocation byte-range to 1-based line/column helper"
```

---

### Task 3: Operator stats + equivalent rate (#20)

**Files:**
- Create: `lib/active_mutator/reporter/operator_stats.rb`
- Modify: `lib/active_mutator.rb` (require), `lib/active_mutator/reporter/terminal.rb`, `lib/active_mutator/reporter/json.rb`
- Test: `spec/active_mutator/reporter/operator_stats_spec.rb`, plus additions to existing reporter expectations

Definition (issue #20): `equivalent_rate = covered_survivors / (killed + survived)`. In this codebase every `:survived` result IS covered (uncovered mutants get status `:uncovered` before scheduling), so covered_survivors == survived count. Deliberate over-estimate; it's a per-operator noise signal, not a score.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/active_mutator/reporter/operator_stats_spec.rb
require "spec_helper"

RSpec.describe ActiveMutator::Reporter::OperatorStats do
  def result(status, operator)
    edit = ActiveMutator::Edit.new(range: 0...1, replacement: "y", description: "d", operator: operator)
    subject = ActiveMutator::Subject.new(name: "Foo#a", file: "foo.rb", byte_range: 0...10,
                                         line_range: 1..2, constant_scope: ["Foo"], kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: "x",
                                           line: 1, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: nil)
  end

  it "aggregates counts and equivalent rate per operator" do
    results = [
      result(:killed, "CallSwap"), result(:killed, "CallSwap"), result(:survived, "CallSwap"),
      result(:killed, "Literal"),
      result(:uncovered, "Literal"), result(:accepted, "Literal"), result(:timeout, "Literal")
    ]
    stats = described_class.call(results)
    expect(stats["CallSwap"]).to eq("killed" => 2, "survived" => 1, "equivalent_rate" => 0.333)
    expect(stats["Literal"]).to eq("killed" => 1, "survived" => 0, "equivalent_rate" => 0.0)
  end

  it "rates an operator with no killed or survived mutants as 0.0" do
    stats = described_class.call([result(:uncovered, "Literal")])
    expect(stats["Literal"]).to eq("killed" => 0, "survived" => 0, "equivalent_rate" => 0.0)
  end

  it "returns an empty hash for no results" do
    expect(described_class.call([])).to eq({})
  end
end
```

- [ ] **Step 2: Run to verify FAIL** — `bundle exec rspec spec/active_mutator/reporter/operator_stats_spec.rb` → uninitialized constant.

- [ ] **Step 3: Implement**

```ruby
# lib/active_mutator/reporter/operator_stats.rb
module ActiveMutator
  module Reporter
    # Per-operator noise signal (issue #20): equivalent_rate =
    # survived / (killed + survived). Every :survived result is covered by
    # construction (uncovered mutants never reach the scheduler), so this is
    # the covered-survivor rate. It deliberately conflates true equivalents
    # with weak assertions — it is an aggregate signal, not a score.
    module OperatorStats
      def self.call(results)
        results.group_by { |r| r.mutation.edit.operator }.to_h do |operator, group|
          killed = group.count { |r| r.status == :killed }
          survived = group.count { |r| r.status == :survived }
          denominator = killed + survived
          rate = denominator.zero? ? 0.0 : (survived.to_f / denominator).round(3)
          [operator, { "killed" => killed, "survived" => survived, "equivalent_rate" => rate }]
        end
      end
    end
  end
end
```

Add `require_relative "active_mutator/reporter/operator_stats"` to `lib/active_mutator.rb` (before the reporter requires that will use it).

- [ ] **Step 4: Run to verify PASS** — same command.

- [ ] **Step 5: Surface in Json reporter (failing test first)**

Add to the existing Json reporter spec (find the summary expectation and extend; if the spec asserts exact keys, add the new one):

```ruby
it "includes per-operator stats in the summary" do
  # reuse the file's existing results/serialization setup
  reporter.summary(results, invalid_count: 0)
  parsed = JSON.parse(out.string)
  expect(parsed["operators"]).to be_a(Hash)
  expect(parsed["operators"].values).to all(include("killed", "survived", "equivalent_rate"))
end
```

Implement in `lib/active_mutator/reporter/json.rb` — add one pair to the `JSON.pretty_generate` hash:

```ruby
          "invalid" => invalid_count,
          "operators" => OperatorStats.call(results),
```

- [ ] **Step 6: Surface in Terminal reporter (failing test first)**

Terminal prints the table only when at least one operator has survivors (keep the happy path quiet). Test:

```ruby
it "prints per-operator equivalent rates when survivors exist" do
  reporter.summary([survived_result], invalid_count: 0)
  expect(out.string).to match(/equivalent-rate by operator/i)
  expect(out.string).to include("CallSwap")
end

it "omits the operator table when nothing survived" do
  reporter.summary([killed_result], invalid_count: 0)
  expect(out.string).not_to match(/equivalent-rate/i)
end
```

Implement in `terminal.rb#summary`, after `print_survivors`:

```ruby
        stats = OperatorStats.call(results)
        noisy = stats.select { |_, s| s["survived"].positive? }
        print_operator_stats(noisy) unless noisy.empty?
```

New private method:

```ruby
      def print_operator_stats(stats)
        @out.puts "", "Equivalent-rate by operator (survived / (killed + survived)):"
        stats.sort_by { |_, s| -s["equivalent_rate"] }.each do |operator, s|
          @out.puts format("  %-24s %5.1f%%  (%d survived / %d killed)",
                           operator, s["equivalent_rate"] * 100, s["survived"], s["killed"])
        end
      end
```

- [ ] **Step 7: Full suite + self-mutation gate**

```bash
bundle exec rspec && bundle exec exe/active_mutator lib --changed
```
Expected: green, exit 0. Watch for `.positive?` → `.zero?` and `round(3)` mutants; the exact-value expectations (0.333) kill the rounding ones.

- [ ] **Step 8: Commit**

```bash
git add lib/active_mutator/reporter/operator_stats.rb lib/active_mutator/reporter/json.rb lib/active_mutator/reporter/terminal.rb lib/active_mutator.rb spec/active_mutator/reporter/
git commit -m "feat: per-operator equivalent-rate metric in summaries

Closes #20"
```

---

### Task 4: Stryker JSON reporter (#17)

**Files:**
- Create: `lib/active_mutator/reporter/stryker_json.rb`
- Modify: `lib/active_mutator.rb` (require), `lib/active_mutator/cli.rb` (format allowlist), `lib/active_mutator/runner.rb` (`build_reporter` + coverage-map injection)
- Test: `spec/active_mutator/reporter/stryker_json_spec.rb`, `spec/active_mutator/cli_spec.rb` addition

**Design (locks in the #17 gotchas):**
- Emits mutation-testing-report-schema v2: `schemaVersion "2"`, integer `thresholds` `{high: 80, low: 60}`, `projectRoot`, `files` keyed by root-relative path with `language: "ruby"`, full `source`, and `mutants`.
- Status map: killed→`Killed`, survived→`Survived`, timeout→`Timeout`, error→`RuntimeError`, uncovered→`NoCoverage`, accepted→`Ignored` (+ `statusReason: "Accepted as equivalent in .active_mutator_accepted.json"` — the ledger stores no free-text reason today, so this is static by design; error/timeout put `result.details` in `statusReason` when present).
- Invalid mutants are discarded before results exist, so they CANNOT appear as `CompileError` mutants; the count goes under the namespaced extras key: top-level `"config" => {"active_mutator" => {"invalid_discarded" => N, "version" => ActiveMutator::VERSION}}`. All tool-specific data stays under that one key so the core document remains schema-valid.
- Locations via `SourceLocation.locate(source, edit.range)` — always 1-based positive.
- `coveredBy` from the coverage map (`map.examples_for(file, mutation.lines)`); `testFiles` emitted so the viewer's test panel works: group every referenced example id by its spec path (the id up to the trailing `[...]`), each test `{id: example_id, name: example_id}`. If no map was injected (unit tests), omit `coveredBy` and `testFiles` entirely — both are optional in the schema.
- Output: written to `.active_mutator/mutation-report.json` under root via `AtomicFile.write` (`.active_mutator/` already exists and self-gitignores); path printed to `@out`. `on_result` prints the same progress chars as Terminal so long runs aren't silent.
- Mutant `id`: sequential index as string, assigned in results order.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/active_mutator/reporter/stryker_json_spec.rb
require "spec_helper"
require "tmpdir"

RSpec.describe ActiveMutator::Reporter::StrykerJson do
  def build_result(status, file:, details: nil)
    source = File.read(file)
    gt = source.byteindex(">")
    edit = ActiveMutator::Edit.new(range: gt...(gt + 1), replacement: ">=",
                                   description: "replace `>` with `>=`", operator: "ConditionalBoundary")
    subject = ActiveMutator::Subject.new(name: "Calc#pos", file: file, byte_range: 0...source.bytesize,
                                         line_range: 1..3, constant_scope: ["Calc"], kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: ">",
                                           line: 2, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: details)
  end

  around do |ex|
    Dir.mktmpdir do |root|
      @root = root
      @file = File.join(root, "lib", "calc.rb")
      FileUtils.mkdir_p(File.dirname(@file))
      File.write(@file, "def pos(x)\n  x > 0\nend\n")
      FileUtils.mkdir_p(File.join(root, ".active_mutator"))
      ex.run
    end
  end

  let(:out) { StringIO.new }
  let(:reporter) { described_class.new(root: @root, out: out) }
  let(:report_path) { File.join(@root, ".active_mutator", "mutation-report.json") }

  def report_after(results, invalid_count: 0)
    reporter.summary(results, invalid_count: invalid_count)
    JSON.parse(File.read(report_path))
  end

  it "writes a schema-v2 document with integer thresholds" do
    report = report_after([build_result(:killed, file: @file)])
    expect(report["schemaVersion"]).to eq("2")
    expect(report["thresholds"]).to eq("high" => 80, "low" => 60)
    expect(report["projectRoot"]).to eq(@root)
  end

  it "keys files by root-relative path with source and language" do
    report = report_after([build_result(:killed, file: @file)])
    file_entry = report.dig("files", "lib/calc.rb")
    expect(file_entry["language"]).to eq("ruby")
    expect(file_entry["source"]).to eq(File.read(@file))
  end

  it "maps every status and emits 1-based locations" do
    statuses = { killed: "Killed", survived: "Survived", timeout: "Timeout",
                 error: "RuntimeError", uncovered: "NoCoverage", accepted: "Ignored" }
    results = statuses.keys.map { |s| build_result(s, file: @file) }
    mutants = report_after(results).dig("files", "lib/calc.rb", "mutants")
    expect(mutants.map { |m| m["status"] }).to match_array(statuses.values)
    mutants.each do |m|
      expect(m.dig("location", "start", "line")).to eq(2)
      expect(m.dig("location", "start", "column")).to eq(5)
      expect(m["mutatorName"]).to eq("ConditionalBoundary")
      expect(m["replacement"]).to eq(">=")
    end
    expect(mutants.map { |m| m["id"] }.uniq.length).to eq(mutants.length)
  end

  it "puts the ledger note in statusReason for accepted, details for error" do
    mutants = report_after([
      build_result(:accepted, file: @file),
      build_result(:error, file: @file, details: "boom")
    ]).dig("files", "lib/calc.rb", "mutants")
    by_status = mutants.to_h { |m| [m["status"], m] }
    expect(by_status["Ignored"]["statusReason"]).to include(".active_mutator_accepted.json")
    expect(by_status["RuntimeError"]["statusReason"]).to eq("boom")
  end

  it "namespaces extras under config.active_mutator" do
    report = report_after([build_result(:killed, file: @file)], invalid_count: 3)
    expect(report.dig("config", "active_mutator", "invalid_discarded")).to eq(3)
    expect(report.dig("config", "active_mutator", "version")).to eq(ActiveMutator::VERSION)
  end

  it "fills coveredBy and testFiles from an injected coverage map" do
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for).and_return(["./spec/calc_spec.rb[1:1]"])
    reporter.coverage_map = map
    report = report_after([build_result(:survived, file: @file)])
    mutant = report.dig("files", "lib/calc.rb", "mutants").first
    expect(mutant["coveredBy"]).to eq(["./spec/calc_spec.rb[1:1]"])
    tests = report.dig("testFiles", "spec/calc_spec.rb", "tests")
    expect(tests).to eq([{ "id" => "./spec/calc_spec.rb[1:1]", "name" => "./spec/calc_spec.rb[1:1]" }])
  end

  it "omits coveredBy and testFiles without a map" do
    report = report_after([build_result(:survived, file: @file)])
    expect(report.dig("files", "lib/calc.rb", "mutants").first).not_to have_key("coveredBy")
    expect(report).not_to have_key("testFiles")
  end

  it "prints the report path and progress chars" do
    reporter.on_result(build_result(:killed, file: @file))
    reporter.summary([build_result(:killed, file: @file)], invalid_count: 0)
    expect(out.string).to start_with(".")
    expect(out.string).to include(".active_mutator/mutation-report.json")
  end
end
```

- [ ] **Step 2: Run to verify FAIL** — `bundle exec rspec spec/active_mutator/reporter/stryker_json_spec.rb` → uninitialized constant.

- [ ] **Step 3: Implement**

```ruby
# lib/active_mutator/reporter/stryker_json.rb
require "json"

module ActiveMutator
  module Reporter
    # mutation-testing-report-schema v2 (the Stryker ecosystem format).
    # Load the written file in https://microsoft.github.io/mutation-testing-elements/
    # for the interactive per-file mutant viewer.
    #
    # Schema constraints honored here: 1-based positive line/column, integer
    # thresholds, tool-specific data only under config.active_mutator.
    # Invalid mutants are discarded before results exist, so they appear as a
    # count in the extras, never as CompileError mutants.
    class StrykerJson
      SCHEMA_URL = "https://git.io/mutation-testing-schema"
      STATUS = { killed: "Killed", survived: "Survived", timeout: "Timeout",
                 error: "RuntimeError", uncovered: "NoCoverage", accepted: "Ignored" }.freeze
      ACCEPTED_REASON = "Accepted as equivalent in #{AcceptedLedger::FILENAME}".freeze
      REPORT_PATH = File.join(".active_mutator", "mutation-report.json")

      # Injected by Runner once the baseline map exists; nil in unit tests.
      attr_writer :coverage_map

      def initialize(root:, out: $stdout)
        @root = root
        @out = out
        @coverage_map = nil
      end

      def on_result(result)
        @out.print(Terminal::CHARS.fetch(result.status))
      end

      def summary(results, invalid_count:)
        report = build_report(results, invalid_count)
        path = File.join(@root, REPORT_PATH)
        AtomicFile.write(path, JSON.pretty_generate(report))
        @out.puts "", "", "Stryker report written to #{REPORT_PATH}"
      end

      private

      def build_report(results, invalid_count)
        mutants_by_file = results.group_by { |r| r.mutation.subject.file }
        report = {
          "$schema" => SCHEMA_URL,
          "schemaVersion" => "2",
          "thresholds" => { "high" => 80, "low" => 60 },
          "projectRoot" => @root,
          "config" => { "active_mutator" => { "invalid_discarded" => invalid_count,
                                              "version" => VERSION } },
          "files" => mutants_by_file.to_h { |file, rs| [relative(file), file_entry(file, rs)] }
        }
        tests = referenced_examples(results)
        report["testFiles"] = test_files(tests) unless tests.empty?
        report
      end

      def file_entry(file, results)
        source = File.read(file)
        ids = 0
        { "language" => "ruby", "source" => source,
          "mutants" => results.map { |r| mutant(r, source) } }
      end

      def mutant(result, source)
        loc = SourceLocation.locate(source, result.mutation.edit.range)
        entry = {
          "id" => next_id,
          "mutatorName" => result.mutation.edit.operator,
          "location" => { "start" => stringify(loc[:start]), "end" => stringify(loc[:end]) },
          "status" => STATUS.fetch(result.status),
          "replacement" => result.mutation.edit.replacement,
          "description" => result.mutation.description
        }
        reason = status_reason(result)
        entry["statusReason"] = reason if reason
        covered = covered_by(result)
        entry["coveredBy"] = covered if covered
        entry
      end

      def status_reason(result)
        return ACCEPTED_REASON if result.status == :accepted

        result.details&.to_s
      end

      def covered_by(result)
        return nil unless @coverage_map

        @coverage_map.examples_for(result.mutation.subject.file, result.mutation.lines)
      end

      def referenced_examples(results)
        results.flat_map { |r| covered_by(r) || [] }.uniq.sort
      end

      # Group example ids by spec path (the id up to the trailing "[...]")
      # so the viewer's test panel resolves coveredBy references.
      def test_files(example_ids)
        example_ids
          .group_by { |id| id.sub(%r{\A\./}, "").sub(/\[.*\]\z/, "") }
          .transform_values do |ids|
            { "tests" => ids.map { |id| { "id" => id, "name" => id } } }
          end
      end

      def next_id
        @next_id = (@next_id || -1) + 1
        @next_id.to_s
      end

      def stringify(position) = { "line" => position[:line], "column" => position[:column] }

      def relative(file) = file.delete_prefix(@root.chomp("/") + "/")
    end
  end
end
```

Note: remove the unused `ids = 0` line if it sneaks in from this listing (`next_id` handles ids); the implementer should write `file_entry` without it:

```ruby
      def file_entry(file, results)
        source = File.read(file)
        { "language" => "ruby", "source" => source,
          "mutants" => results.map { |r| mutant(r, source) } }
      end
```

Add `require_relative "active_mutator/reporter/stryker_json"` to `lib/active_mutator.rb` (after terminal/json requires — it references `Terminal::CHARS`).

- [ ] **Step 4: Wire CLI + Runner (failing tests first)**

CLI spec addition:

```ruby
it "parses --format stryker-json" do
  expect(described_class.parse(["--format", "stryker-json"]).format).to eq(:stryker_json)
end
```

Runner spec addition (follow the file's existing stubbing style for `Runner`):

```ruby
it "builds a StrykerJson reporter for :stryker_json format" do
  config = build_config(format: :stryker_json)  # reuse the spec's config helper
  reporter = ActiveMutator::Runner.new(config).instance_variable_get(:@reporter)
  expect(reporter).to be_a(ActiveMutator::Reporter::StrykerJson)
end
```

`cli.rb` format option becomes:

```ruby
        o.on("--format FMT", %w[terminal json stryker-json], "Output format") { |v| options[:format] = v.tr("-", "_").to_sym }
```

`runner.rb#build_reporter` becomes:

```ruby
    def build_reporter
      case @config.format
      when :json then Reporter::Json.new
      when :stryker_json then Reporter::StrykerJson.new(root: @config.root)
      else Reporter::Terminal.new
      end
    end
```

`runner.rb#call`, right after `map = Baseline.new(...)`:

```ruby
      @reporter.coverage_map = map if @reporter.respond_to?(:coverage_map=)
```

- [ ] **Step 5: Full suite**

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 6: End-to-end sanity on the fixture project**

```bash
ACTIVE_MUTATOR_E2E=1 ACTIVE_MUTATOR_INTEGRATION=1 bundle exec rspec spec/e2e spec/integration 2>/dev/null || bundle exec rspec
cd spec/fixtures/tiny_project 2>/dev/null && bundle exec ruby -e 'exit' && cd -
```

Simplest real check — run the tool on itself with the new format:

```bash
bundle exec exe/active_mutator lib --subject "ActiveMutator::SourceLocation.*" --format stryker-json
ruby -rjson -e 'r = JSON.parse(File.read(".active_mutator/mutation-report.json")); puts r["schemaVersion"]; puts r["files"].keys'
```
Expected: `2` and `lib/active_mutator/source_location.rb`; exit 0 (Task 2's specs kill its mutants).

- [ ] **Step 7: Self-mutation gate**

Run: `bundle exec exe/active_mutator lib --changed`
Expected: exit 0. The status-map hash literal and `fetch` calls generate many mutants; the all-statuses spec kills the map ones.

- [ ] **Step 8: Commit**

```bash
git add lib/active_mutator/reporter/stryker_json.rb lib/active_mutator.rb lib/active_mutator/cli.rb lib/active_mutator/runner.rb spec/active_mutator/reporter/stryker_json_spec.rb spec/active_mutator/cli_spec.rb spec/active_mutator/runner_spec.rb
git commit -m "feat: --format stryker-json emits mutation-testing-report-schema v2

Closes #17"
```

---

### Task 5: GitHub Actions annotation reporter (#19)

**Files:**
- Create: `lib/active_mutator/reporter/github.rb`
- Modify: `lib/active_mutator.rb` (require), `lib/active_mutator/cli.rb` (allowlist), `lib/active_mutator/runner.rb` (`build_reporter`)
- Test: `spec/active_mutator/reporter/github_spec.rb`

**Design:** `--format github`. One `::warning file=...,line=...,col=...::message` line per survivor, plus the normal terminal-style progress chars and count summary (annotations parse regardless of surrounding output). File paths root-relative (GH matches them against the checkout). Message must be single-line — GH annotations break on raw newlines — so encode the diff inline. Percent-encode `%`, `\r`, `\n` in the message per workflow-command rules.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/active_mutator/reporter/github_spec.rb
require "spec_helper"

RSpec.describe ActiveMutator::Reporter::Github do
  def build_result(status, description: "replace `>` with `>=`", snippet: "x > 0", replacement: "x >= 0")
    edit = ActiveMutator::Edit.new(range: 13...18, replacement: replacement,
                                   description: description, operator: "ConditionalBoundary")
    subject = ActiveMutator::Subject.new(name: "Calc#pos", file: "/repo/lib/calc.rb", byte_range: 0...20,
                                         line_range: 1..3, constant_scope: ["Calc"], kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: snippet,
                                           line: 2, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: nil)
  end

  let(:out) { StringIO.new }
  let(:reporter) { described_class.new(root: "/repo", out: out) }

  it "emits one ::warning line per survivor with root-relative path" do
    reporter.summary([build_result(:survived), build_result(:killed)], invalid_count: 0)
    warnings = out.string.lines.select { |l| l.start_with?("::warning") }
    expect(warnings.length).to eq(1)
    expect(warnings.first).to start_with("::warning file=lib/calc.rb,line=2,title=Surviving mutant::")
    expect(warnings.first).to include("Calc#pos")
    expect(warnings.first).to include("replace `>` with `>=`")
  end

  it "percent-encodes newlines and percents in the message" do
    result = build_result(:survived, description: "multi\nline 100%")
    reporter.summary([result], invalid_count: 0)
    warning = out.string.lines.find { |l| l.start_with?("::warning") }
    expect(warning).to include("multi%0Aline 100%25")
    expect(warning.scan("\n").length).to eq(1)  # only the trailing newline
  end

  it "still prints progress chars and the count summary" do
    reporter.on_result(build_result(:killed))
    reporter.summary([build_result(:killed)], invalid_count: 0)
    expect(out.string).to start_with(".")
    expect(out.string).to include("killed: 1")
  end
end
```

- [ ] **Step 2: Run to verify FAIL** — uninitialized constant.

- [ ] **Step 3: Implement**

```ruby
# lib/active_mutator/reporter/github.rb
module ActiveMutator
  module Reporter
    # GitHub Actions workflow-command projection (issue #19): one ::warning
    # annotation per surviving mutant, inlined on the PR diff. Everything
    # else mirrors the terminal reporter so CI logs stay readable.
    class Github
      def initialize(root:, out: $stdout)
        @root = root
        @terminal = Terminal.new(out: out)
        @out = out
      end

      def on_result(result) = @terminal.on_result(result)

      def summary(results, invalid_count:)
        @terminal.summary(results, invalid_count: invalid_count)
        results.select { |r| r.status == :survived }.each { |r| annotate(r) }
      end

      private

      def annotate(result)
        m = result.mutation
        file = m.subject.file.delete_prefix(@root.chomp("/") + "/")
        message = "#{m.subject.name}: #{m.description} | - #{m.original_snippet} | + #{m.edit.replacement}"
        @out.puts "::warning file=#{file},line=#{m.line},title=Surviving mutant::#{encode(message)}"
      end

      # GitHub workflow commands terminate at a raw newline; percent-encode
      # per https://github.com/actions/toolkit runner rules.
      def encode(message)
        message.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      end
    end
  end
end
```

Wire-up:
- `lib/active_mutator.rb`: `require_relative "active_mutator/reporter/github"` (after terminal).
- `cli.rb`: allowlist `%w[terminal json stryker-json github]`.
- `runner.rb#build_reporter`: add `when :github then Reporter::Github.new(root: @config.root)`.
- CLI spec: `expect(described_class.parse(["--format", "github"]).format).to eq(:github)`.

- [ ] **Step 4: Full suite** — `bundle exec rspec` → PASS.

- [ ] **Step 5: Self-mutation gate** — `bundle exec exe/active_mutator lib --changed` → exit 0. `gsub` chain mutants (drop a link, swap encodings) die on the percent-encoding spec.

- [ ] **Step 6: Real-workflow check**

Update the mutation job in `.github/workflows/ci.yml` to use the new format (annotations land inline on the PR diff instead of only the job log):

```yaml
      - name: Self-mutation on PR diff (advisory)
        run: |
          bundle exec exe/active_mutator lib --since "origin/${{ github.base_ref }}" --format github || {
            echo "::warning title=Surviving mutants::Self-mutation found unaccepted survivors in this PR's diff (advisory until #25 is triaged). See job log."
          }
```

- [ ] **Step 7: Commit**

```bash
git add lib/active_mutator/reporter/github.rb lib/active_mutator.rb lib/active_mutator/cli.rb lib/active_mutator/runner.rb spec/active_mutator/reporter/github_spec.rb spec/active_mutator/cli_spec.rb .github/workflows/ci.yml
git commit -m "feat: --format github emits PR annotations for survivors

Closes #19"
```

---

### Task 6: Docs, dogfood, #13/#14 decisions, phase close

**Files:**
- Modify: `README.md`, `docs/dogfood-log.md`
- No code.

- [ ] **Step 1: README updates**

- `--format` rows/mentions: `terminal|json|stryker-json|github` in the flags table and Usage section.
- New short section after "The dev loop":

```markdown
## Reports

`--format stryker-json` writes `.active_mutator/mutation-report.json` in the
Stryker [mutation-testing-report-schema](https://github.com/stryker-mutator/mutation-testing-elements)
v2 format. Open it in the
[Stryker report viewer](https://microsoft.github.io/mutation-testing-elements/)
for per-file mutant maps with inline diffs, filterable by status.

`--format github` prints one `::warning` annotation per surviving mutant, so
survivors show inline on the PR diff. Pairs with the CI recipe:

    bundle exec active_mutator --since origin/main --format github
```

- CI recipe section: mention `--format github`.
- Summaries: note per-operator equivalent-rate table appears when survivors exist.

- [ ] **Step 2: Dogfood on payint**

```bash
cd ~/Documents/enovis/payint   # branch active-mutator-poc
time bundle exec active_mutator app/models --subject "Document#size_category"                       # regression smoke vs phase-1 rows
bundle exec active_mutator app/models --subject "Document" --format stryker-json                    # real report
ruby -rjson -e 'r=JSON.parse(File.read(".active_mutator/mutation-report.json")); puts r["files"].keys; puts r["files"].values.sum { |f| f["mutants"].size }'
bundle exec active_mutator app/models --subject "Document" --format github | grep -c "^::warning" || true
```

Then load `payint/.active_mutator/mutation-report.json` in https://microsoft.github.io/mutation-testing-elements/ (controller asks the user to drag-drop the file, or verifies structurally if headless). Confirm: inline diffs render, statuses filter, coveredBy tests listed.

Log rows in `docs/dogfood-log.md` (wall time, score, notes: report size, viewer OK).

- [ ] **Step 3: Decide #13 and #14**

- #13 HTML report: the Stryker viewer + `--format stryker-json` covers per-file mutant maps with inline diffs and status filters — exactly #13's ask. Close #13:

```bash
gh issue close 13 --comment "Subsumed by #17: \`--format stryker-json\` + the Stryker report viewer (https://microsoft.github.io/mutation-testing-elements/) provides per-file mutant maps, inline diffs, and status filtering without an HTML pipeline in the core gem. README documents the workflow."
```

- #14 Editor integration: keep open, re-scope:

```bash
gh issue comment 14 --body "Re-scoped after #17: build as an LSP shim reading the Stryker JSON report (\`.active_mutator/mutation-report.json\`) — stable schema, locations already 1-based. Deferred to backlog; no core-gem changes required."
```

- [ ] **Step 4: Full self-run + commit**

```bash
cd ~/Documents/enovis/active_mutator
bundle exec rspec
bundle exec exe/active_mutator lib   # full self-run: exit 0 or survivors pre-exist in #25's list
git add README.md docs/dogfood-log.md
git commit -m "docs: stryker-json + github formats, operator stats; phase 2 dogfood log"
```

- [ ] **Step 5: Phase close-out**

- Push `phase-2-reporting`, open PR (base: whatever phase-1-quick-wins merged into — `main` if PR #26 merged, else stack on `phase-1-quick-wins`).
- Tick Phase 2 checkboxes in `docs/superpowers/plans/2026-07-15-issue-backlog-roadmap.md`.
- This plan file stays live until the PR merges, then moves to `docs/superpowers/plans/archive/`.

---

## Self-review

- **Spec coverage:** #17 → Task 4 (all gotchas: 1-based locations Task 2, integer thresholds, AtomicFile, namespaced extras, coveredBy, golden-style spec). #20 → Task 3 (rate definition matches issue; covered-survivor == survived justified). #19 → Task 5 (`--format github` per roadmap recommendation, ~60 lines, root-relative paths, encoding). #13/#14 → Task 6 decisions. Foundation gap (no operator identity) → Task 1.
- **Placeholders:** none; every code step has full code. Task 4 Step 3 includes an explicit correction note for the stray `ids = 0` line.
- **Type consistency:** `Edit.operator` (Task 1) consumed by `OperatorStats` (Task 3), `mutatorName` (Task 4). `SourceLocation.locate(source, range) → {start: {line:, column:}, end: {...}}` (Task 2) consumed in Task 4. `StrykerJson.new(root:, out:)` + `coverage_map=` consistent between Task 4 spec and Runner wiring. `Github.new(root:, out:)` matches its spec.
- **Known deliberate simplifications:** static `statusReason` for accepted (ledger has no reason field); char-vs-byte columns on multibyte lines cosmetic only; no `killedBy` (worker details don't carry example ids).
