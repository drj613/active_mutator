# active_mutator Issue Backlog Roadmap (Phases 1–6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Close all 22 open GitHub issues in six phases, each phase gated by TDD, a self-mutation run, and a dogfood run on payint's `active-mutator-poc` branch.

**Architecture:** active_mutator is a Prism-based mutation tester: `CLI.parse` → `Config` → `Runner#call` (preload, `Baseline` coverage map, `SubjectFinder`, `Engine` + `Operators::Base.REGISTRY`, `Runner#plan_work`, `Scheduler` forks `Worker`, `Reporter::{Terminal,Json}`). Phases are ordered so early wins (fail-fast, subject filters) speed up every later dogfood run, and the Stryker reporter (Phase 2) unlocks three downstream issues.

**Tech Stack:** Ruby, Prism, RSpec, optparse, fork-based workers. Dogfood target: `~/Documents/enovis/payint` (Rails monolith, `gem "active_mutator", path: "../active_mutator"` — edits are live, no release needed).

---

## Standing protocol (every task, every phase)

**TDD:** red → green → commit, per task steps below. `bundle exec rspec` must be green before any commit.

**Self-mutation gate (end of each task):**
```bash
cd ~/Documents/enovis/active_mutator
bundle exec exe/active_mutator lib --changed
```
Expected: exit 0 (no unaccepted survivors in the code you just wrote). A survivor = your tests miss a behavior; add the killing test before commit.

**Dogfood gate (end of each phase):**
```bash
cd ~/Documents/enovis/payint   # branch: active-mutator-poc
bundle exec active_mutator app/models --subject "Document#size_category"   # smoke: known-good subject
bundle exec active_mutator --changed                                                    # exercise the new feature on real diff
```
Record wall time + score in `docs/dogfood-log.md` (create in Phase 1, Task 0). Any regression vs the previous phase's entry blocks phase close.

**Issue hygiene:** close each GitHub issue in the commit/PR that ships it (`Closes #N`).

---

## Phase map

| Phase | Issues | Theme | Detail level in this doc |
|---|---|---|---|
| 1 | #18, #7, #1, #8, #22(partial: `--max-mutants`, `--debug-plan`) | Quick wins: perf + subject selection | **Full TDD tasks below** |
| 2 | #17, #19, #20, decide #13/#14 | Reporting pipeline | Task outline; detailed plan at phase start |
| 3 | #22(rest: config file, `--fail-at` decision) | Config + CI gates | Task outline |
| 4 | #21, #9, #11 | Bench harness + accuracy | Task outline |
| 5 | #4, #5, #3, #6, #2 | Mutation coverage expansion | Task outline |
| 6 | #15, #10, #12, #16 | Defer/close decisions | Decision checklist |

Phases 2–6: at phase start, run superpowers:writing-plans again to produce `docs/superpowers/plans/YYYY-MM-DD-phase-N-<theme>.md` with full TDD steps, using the outlines below as the spec.

---

# Phase 1 — detailed tasks

### Task 0: Dogfood log + baseline measurement

**Files:**
- Create: `docs/dogfood-log.md`

- [x] **Step 1: Capture pre-change baseline on payint**

```bash
cd ~/Documents/enovis/payint
git status   # confirm branch active-mutator-poc, note dirty files
time bundle exec active_mutator app/models
```

- [x] **Step 2: Record it**

Create `docs/dogfood-log.md` in active_mutator:

```markdown
# Dogfood log — payint active-mutator-poc

| Date | Phase | Command | Wall time | Score | Survivors | Notes |
|---|---|---|---|---|---|---|
| 2026-07-15 | pre-1 | active_mutator app/models | <fill> | <fill> | <fill> | baseline before fail-fast |
```

- [x] **Step 3: Commit**

```bash
cd ~/Documents/enovis/active_mutator
git add docs/dogfood-log.md && git commit -m "docs: start dogfood log for payint POC runs"
```

---

### Task 1: Worker fail-fast (#18)

**Files:**
- Modify: `lib/active_mutator/worker.rb:22-33` (`Worker#run`)
- Test: `spec/active_mutator/worker_spec.rb`

**Design note:** set `RSpec.configuration.fail_fast = 1` after `runner.setup` and before `runner.run_specs`. Kill semantics unchanged: `run_specs` still returns non-zero on the first failure, so `killed` vs `survived` mapping at `worker.rb:30` is untouched. The parent-side process-group KILL timeout path lives in the Scheduler, not the Worker — fail-fast only makes the fork exit *sooner*, never later, so the timeout path is unaffected (verify in Step 5).

- [x] **Step 1: Write the failing test**

Add to `spec/active_mutator/worker_spec.rb` (follow the existing stubbing style in that file — it stubs `RSpec::Core::Runner`):

```ruby
it "sets fail_fast so the first killing example ends the run" do
  fail_fast_seen = nil
  allow(runner).to receive(:run_specs) do
    fail_fast_seen = RSpec.configuration.fail_fast
    1
  end

  described_class.run(mutation, example_ids, writer)

  expect(fail_fast_seen).to eq(1)
end
```

(Adapt `runner`/`mutation`/`example_ids`/`writer` let-blocks to the file's existing setup; if the file has none for the runner, stub `RSpec::Core::Runner.new` to return an instance double with `setup` and `run_specs`.)

- [x] **Step 2: Run test, verify it fails**

```bash
bundle exec rspec spec/active_mutator/worker_spec.rb -e "fail_fast"
```
Expected: FAIL — `fail_fast_seen` is `nil`/`false`.

- [x] **Step 3: Minimal implementation**

In `Worker#run`, after `runner.setup(devnull, devnull)`:

```ruby
      runner.setup(devnull, devnull)   # loads spec files -> loads the app
      # One failure kills the mutant; running the rest of the covering set
      # is pure waste inside the fork.
      RSpec.configuration.fail_fast = 1
      Inserter.new.insert(@mutation)   # now the target constant exists
```

- [x] **Step 4: Run full suite**

```bash
bundle exec rspec
```
Expected: PASS. Pay attention to `spec/e2e/` — those exercise real forks and prove killed/survived/timeout exit semantics still hold.

- [x] **Step 5: Verify timeout path untouched**

```bash
bundle exec rspec spec/active_mutator/scheduler_spec.rb
ACTIVE_MUTATOR_E2E=1 bundle exec rspec spec/e2e   # e2e specs are env-gated (see spec_helper.rb tags)
```
Expected: PASS (timeout kill via process group unchanged). If the gate var differs, check `spec/spec_helper.rb` for the exact `ACTIVE_MUTATOR_*` names.

- [x] **Step 6: Self-mutation + dogfood timing**

```bash
bundle exec exe/active_mutator lib --changed   # NOTE: positional args are directories, not files
cd ~/Documents/enovis/payint && time bundle exec active_mutator app/models --subject "Document#size_category"
```
Expected: exit 0; payint wall time ≤ Task 0 baseline (should improve on multi-example covering sets). Log the row in `docs/dogfood-log.md`.

- [x] **Step 7: Commit**

```bash
git add lib/active_mutator/worker.rb spec/active_mutator/worker_spec.rb docs/dogfood-log.md
git commit -m "feat: fail-fast in worker — first killing example ends the run

Closes #18"
```

---

### Task 2: `--exclude` path globs (#7)

**Files:**
- Modify: `lib/active_mutator/cli.rb:13-47`, `lib/active_mutator/config.rb`, `lib/active_mutator/runner.rb:77-88` (`discover_subjects`)
- Test: `spec/active_mutator/cli_spec.rb`, `spec/active_mutator/runner_spec.rb`

- [x] **Step 1: Failing CLI test**

```ruby
it "collects repeatable --exclude patterns" do
  config = described_class.parse(["lib", "--exclude", "lib/generated/**", "--exclude", "**/legacy/*"])
  expect(config.exclude).to eq(["lib/generated/**", "**/legacy/*"])
end

it "defaults exclude to empty" do
  expect(described_class.parse([]).exclude).to eq([])
end
```

- [x] **Step 2: Run, verify fail** — `bundle exec rspec spec/active_mutator/cli_spec.rb` → FAIL (no `exclude` key).

- [x] **Step 3: Implement CLI + Config**

`cli.rb` defaults hash: add `exclude: [],`. Option:

```ruby
o.on("--exclude PAT", "Skip files matching glob, relative to root (repeatable)") { |v| options[:exclude] << v }
```

`config.rb`: add `exclude` to the Config members (mirror how `requires` is declared).

- [x] **Step 4: Failing Runner test**

In `spec/active_mutator/runner_spec.rb`, near existing `discover_subjects`/`plan_work` tests:

```ruby
it "drops files matching exclude globs during discovery" do
  Dir.mktmpdir do |root|
    FileUtils.mkdir_p(File.join(root, "lib/generated"))
    File.write(File.join(root, "lib/keep.rb"), "class Keep; def a; 1; end; end\n")
    File.write(File.join(root, "lib/generated/skip.rb"), "class Skip; def a; 1; end; end\n")
    config = ActiveMutator::Config.new(paths: ["lib"], root: root, exclude: ["lib/generated/**"], ...) # fill remaining kwargs as other tests do
    subjects = ActiveMutator::Runner.new(config, reporter: fake_reporter).send(:discover_subjects)
    expect(subjects.map(&:name)).to eq(["Keep#a"])
  end
end
```

- [x] **Step 5: Implement in `discover_subjects`**

After the glob, before `SubjectFinder.call`:

```ruby
      subjects = paths
        .flat_map { |p| Dir[File.join(@config.root, p, "**", "*.rb")] }
        .reject { |file| excluded?(file) }
        .sort.flat_map { |file| SubjectFinder.call(file) }
```

New private method:

```ruby
    def excluded?(file)
      relative = file.delete_prefix("#{@config.root}/")
      @config.exclude.any? do |pattern|
        File.fnmatch?(pattern, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
    end
```

- [x] **Step 6: Full suite + self-mutation**

```bash
bundle exec rspec && bundle exec exe/active_mutator lib --changed
```
Expected: green, exit 0. (Self-mutation here directly stress-tests the new code: `excluded?` boundary mutants like `any?`→`none?` must die.)

- [x] **Step 7: Dogfood on payint**

```bash
cd ~/Documents/enovis/payint
bundle exec active_mutator app/models --exclude "app/models/concerns/**" --subject "Document#size_category"
```
Expected: runs; a second run with `--exclude "app/models/document*"` finds 0 subjects.

- [x] **Step 8: Commit** — `git commit -m "feat: --exclude path globs in subject discovery" -m "Closes #7"` (with the four touched files).

---

### Task 3: Per-method opt-out magic comment (#1)

**Files:**
- Modify: `lib/active_mutator/subject_finder.rb`
- Test: `spec/active_mutator/subject_finder_spec.rb`

**Design:** marker `# active_mutator:skip` on the line directly above `def` (or above `def`'s first decorator-free line). Prism supplies comments via `Prism.parse(...).comments`.

- [x] **Step 1: Failing test**

```ruby
it "skips a def annotated with active_mutator:skip on the previous line" do
  file = write_fixture(<<~RUBY)
    class Foo
      # active_mutator:skip
      def skipped; 1; end

      def kept; 2; end
    end
  RUBY
  names = described_class.call(file).map(&:name)
  expect(names).to eq(["Foo#kept"])
end

it "tolerates surrounding text and whitespace in the marker" do
  file = write_fixture(<<~RUBY)
    class Foo
      #   active_mutator: skip -- generated delegator
      def skipped; 1; end
    end
  RUBY
  expect(described_class.call(file)).to be_empty
end
```

(Use the spec file's existing fixture-writing helper; if none, `Tempfile`.)

- [x] **Step 2: Run, verify FAIL** — both subjects currently returned.

- [x] **Step 3: Implement**

```ruby
    SKIP_MARKER = /#\s*active_mutator:\s*skip\b/

    def self.call(file)
      result = Prism.parse(File.read(file))
      return [] unless result.success?

      skip_lines = result.comments
        .select { |c| c.slice.match?(SKIP_MARKER) }
        .to_set { |c| c.location.start_line }
      finder = new(file, skip_lines: skip_lines)
      finder.visit(result.value)
      finder.subjects
    end

    def initialize(file, skip_lines: Set.new)
      @file = file
      @skip_lines = skip_lines
      ...
    end
```

In `visit_def_node`, first line:

```ruby
      return if @skip_lines.include?(node.location.start_line - 1)
```

(`require "set"` at top if not already loaded.)

- [x] **Step 4: Full suite + self-mutation** — `bundle exec rspec && bundle exec exe/active_mutator lib --changed` → green, exit 0.

- [x] **Step 5: Dogfood** — on payint, annotate one method in a POC-branch file, run `bundle exec active_mutator <that file>`, confirm subject absent; revert the annotation.

- [x] **Step 6: Document** — README subject-filters section: add the marker with one example.

- [x] **Step 7: Commit** — `"feat: per-method opt-out via # active_mutator:skip comment" / "Closes #1"`.

---

### Task 4: Subject expression language (#8)

**Files:**
- Create: `lib/active_mutator/subject_matcher.rb`
- Modify: `lib/active_mutator/runner.rb:82` (filter line), `lib/active_mutator.rb` (require), `lib/active_mutator/cli.rb:31` (help text)
- Test: `spec/active_mutator/subject_matcher_spec.rb`

**Grammar (keep tiny):**
- `Foo::Bar#baz` / `Foo::Bar.baz` — exact (today's behavior)
- `Foo::Bar` — every method of that constant (`#` and `.`)
- `Foo::Bar*` — namespace prefix (matches `Foo::Bar`, `Foo::Barn`, `Foo::Bar::Qux#m`)
- `Foo::Bar#*` — instance methods only; `Foo::Bar.*` — singleton methods only

- [x] **Step 1: Failing tests**

```ruby
RSpec.describe ActiveMutator::SubjectMatcher do
  def match?(expr, name) = described_class.new(expr).match?(name)

  it("exact instance")        { expect(match?("Foo::Bar#baz", "Foo::Bar#baz")).to be true }
  it("exact rejects other")   { expect(match?("Foo::Bar#baz", "Foo::Bar#qux")).to be false }
  it("bare constant, all")    { expect(match?("Foo::Bar", "Foo::Bar#baz")).to be true }
  it("bare constant, dot")    { expect(match?("Foo::Bar", "Foo::Bar.build")).to be true }
  it("bare rejects nested")   { expect(match?("Foo::Bar", "Foo::Bar::Qux#m")).to be false }
  it("star namespace")        { expect(match?("Foo::Bar*", "Foo::Bar::Qux#m")).to be true }
  it("star same-prefix const"){ expect(match?("Foo::Bar*", "Foo::Barn#m")).to be true }
  it("hash star instance")    { expect(match?("Foo::Bar#*", "Foo::Bar#baz")).to be true }
  it("hash star not dot")     { expect(match?("Foo::Bar#*", "Foo::Bar.build")).to be false }
  it("dot star singleton")    { expect(match?("Foo::Bar.*", "Foo::Bar.build")).to be true }
end
```

- [x] **Step 2: Run, verify FAIL** (uninitialized constant).

- [x] **Step 3: Implement**

```ruby
module ActiveMutator
  # Tiny subject-expression grammar for --subject:
  #   Foo::Bar#baz  exact          Foo::Bar   all methods of the constant
  #   Foo::Bar*     namespace      Foo::Bar#* instance-only   Foo::Bar.* singleton-only
  class SubjectMatcher
    def initialize(expression)
      @regexp = compile(expression)
    end

    def match?(name) = @regexp.match?(name)

    private

    def compile(expr)
      case expr
      when /\A(.+)([#.])\*\z/  then /\A#{Regexp.escape($1)}#{Regexp.escape($2)}.+\z/
      when /\A(.+)\*\z/        then /\A#{Regexp.escape($1)}/
      when /[#.]/              then /\A#{Regexp.escape(expr)}\z/
      else                          /\A#{Regexp.escape(expr)}[#.][^:]+\z/
      end
    end
  end
end
```

Runner filter line becomes:

```ruby
      if @config.subject_filter
        matcher = SubjectMatcher.new(@config.subject_filter)
        subjects = subjects.select { |s| matcher.match?(s.name) }
      end
```

CLI help text: `"Mutate matching subjects: Foo::Bar#baz, Foo::Bar, Foo::Bar*, Foo::Bar#*"`.

- [x] **Step 4: Full suite + self-mutation** — green, exit 0. Regex-compile mutants (`.+`→`.*`, anchors) are prime survivor candidates; kill any with added examples rather than accepting.

- [x] **Step 5: Dogfood** — payint: `bundle exec active_mutator app/models --subject "Document#*"` runs all instance methods; `--subject "Document"` matches both `#` and `.` subjects.

- [x] **Step 6: Commit** — `"feat: subject expression language for --subject" / "Closes #8"`.

---

### Task 5: `--max-mutants` + `--debug-plan` (#22 partial)

**Files:**
- Modify: `lib/active_mutator/cli.rb`, `lib/active_mutator/config.rb`, `lib/active_mutator/runner.rb:8-31` (`call`)
- Test: `spec/active_mutator/cli_spec.rb`, `spec/active_mutator/runner_spec.rb`

**Design:** mutants are already deterministic (files sorted at discovery, operators walk the AST in order), so `--max-mutants N` = `mutations.first(N)` after analysis, before ledger/planning. `--debug-plan` prints one JSON object per planned mutant (subject, description, file, line, lane, timeout, example count) and exits 0 without forking.

- [x] **Step 1: Failing CLI tests**

```ruby
it "parses --max-mutants" do
  expect(described_class.parse(["--max-mutants", "50"]).max_mutants).to eq(50)
end

it "parses --debug-plan" do
  expect(described_class.parse(["--debug-plan"]).debug_plan).to be true
end
```

- [x] **Step 2: FAIL, then implement CLI/Config**

Defaults: `max_mutants: nil, debug_plan: false`. Options:

```ruby
o.on("--max-mutants N", Integer, "Deterministically sample the first N mutants") { |v| options[:max_mutants] = v }
o.on("--debug-plan", "Print the planned mutant list as JSON and exit") { options[:debug_plan] = true }
```

- [x] **Step 3: Failing Runner tests**

```ruby
it "caps mutations at max_mutants before planning" # build 3 mutations, config max_mutants: 2, assert plan_work receives 2
it "debug_plan prints items as JSON and skips the scheduler" # assert Scheduler never instantiated, output parses as JSON, exit code 0
```

Write these against `Runner#call` with stubbed collaborators, matching the stubbing style already in `runner_spec.rb`.

- [x] **Step 4: Implement in `Runner#call`**

After `mutations = analyses.flat_map(&:mutations)`:

```ruby
      mutations = mutations.first(@config.max_mutants) if @config.max_mutants
```

After `items, pre_results = plan_work(...)`:

```ruby
      return debug_plan(items, pre_results) if @config.debug_plan
```

New private method:

```ruby
    def debug_plan(items, pre_results)
      plan = items.map do |i|
        { "subject" => i.mutation.subject.name, "description" => i.mutation.description,
          "file" => i.mutation.subject.file, "line" => i.mutation.line,
          "lane" => i.lane.to_s, "timeout" => i.timeout.round(2),
          "examples" => i.example_ids.size }
      end
      skipped = pre_results.group_by { |r| r.status.to_s }.transform_values(&:size)
      puts JSON.pretty_generate("planned" => plan, "pre_resolved" => skipped)
      0
    end
```

- [x] **Step 5: Full suite + self-mutation** — green, exit 0.

- [x] **Step 6: Dogfood** — payint: `bundle exec active_mutator app/models --debug-plan` shows plan instantly; `--max-mutants 5` runs exactly 5.

- [x] **Step 7: Commit** — `"feat: --max-mutants sampling and --debug-plan dry run" / "Refs #22"` (issue stays open for config file + --fail-at).

---

### Task 6: Phase 1 close-out

- [x] Full payint dogfood: `cd ~/Documents/enovis/payint && bundle exec active_mutator --changed` on the POC branch; log wall time/score row.
- [x] `bundle exec exe/active_mutator lib` (full self-run, not `--changed`) — exit 0 or every survivor triaged (killed with a new test, or accepted with ledger reason).
- [x] Close #18, #7, #1, #8 on GitHub; comment progress on #22.
- [x] Update README: `--exclude`, skip comment, subject expressions, `--max-mutants`, `--debug-plan`.

---

# Phase 2 — Reporting pipeline (#17, #19, #20; decide #13/#14)

Author the detailed plan at phase start (`superpowers:writing-plans`), from this spec:

**Task order:** #17 → #20 → #19 → decision on #13/#14.

**#17 Stryker JSON reporter** (~1 day)
- Create `lib/active_mutator/reporter/stryker_json.rb`; wire `--format stryker-json` in `cli.rb:33` (extend the `%w[terminal json]` allowlist) and `Runner#build_reporter`.
- Schema: mutation-testing-report-schema v2. Status map: killed→Killed, survived→Survived, timeout→Timeout, error→RuntimeError, uncovered→NoCoverage, accepted→Ignored (+ ledger reason in `statusReason`), invalid→CompileError.
- Known gotchas (pre-paid by mutalisk): 1-based positive line/column always; integer `thresholds.high/low`; atomic write via existing `AtomicFile` (`lib/active_mutator/atomic_file.rb`); tool-specific extras under an `active_mutator` key only; fill `coveredBy` from the coverage map.
- TDD anchor: golden-fixture spec — full report for a small fixture project, byte-compared; plus a schema-validation spec if a validator gem is cheap, else structural assertions.
- Dogfood: generate report on payint POC branch, load it in the Stryker HTML viewer (https://microsoft.github.io/mutation-testing-elements/), confirm inline diffs render.

**#20 Equivalent-rate metric** (~½ day)
- `equivalent_rate = covered_survivors / (killed + survived)`, covered-survivor = survived with non-empty coveredBy; uncovered excluded.
- Aggregate per operator in the summary of both reporters; this is the input for the Phase 5 operator-graduation gate (#6/#5).
- TDD anchor: unit spec on a results array with known statuses per operator.

**#19 GitHub Actions annotation reporter** (~60 lines, blocked by #17)
- Pure projection of the Stryker JSON into `::warning file=...,line=...,col=...::<description>` lines, one per survivor. New `--format github` or a post-processing subcommand — decide in the phase plan (recommend `--format github` for symmetry).
- Dogfood: run in a scratch workflow on this repo with `--since origin/main`.

**#13 HTML report / #14 editor integration — decision, not code:** after #17 ships, evaluate whether Stryker viewer subsumes #13 (expected: yes → close #13 with a README pointer). #14 stays open, re-scoped as "LSP shim reading Stryker JSON", deferred to backlog.

---

# Phase 3 — Config file + CI gates (#22 remainder)

**`.active_mutator.yml`**
- Layering: built-in defaults < config file < CLI flags. Load in `CLI.parse` before OptionParser applies flags; keys mirror option names (`jobs`, `serial_patterns`, `exclude`, `timeout_factor`, `timeout_floor`, `paths`, `format`).
- TDD anchor: precedence matrix spec (file only, flag only, both → flag wins) + unknown-key warning spec.

**`--fail-at SCORE` — decision required before code:** current model (any unaccepted survivor fails) is stricter and stays the default. Recommendation: add `--fail-at` as an *opt-in relaxation* for legacy adoption; when set, exit 1 only if score < threshold, and print the survivor count regardless. Confirm with maintainer (user) at phase start, then TDD `Runner#exit_code`.
- Dogfood: commit a `.active_mutator.yml` to payint POC branch encoding the flags currently passed by hand; run bare `bundle exec active_mutator --changed`.

Close #22 at phase end.

---

# Phase 4 — Bench harness + accuracy (#21, #9, #11)

**#21 Bench harness (do first — it gates the other two)**
- `bench/` directory: 3–5 SHA-pinned targets (one small gem, one mid-size gem, one Rails app with system specs — payint POC branch can be the Rails cell if pinning is acceptable; else a public app).
- Per cell: setup once (bundle install + baseline), loop flag variations (`--jobs` × `--timeout-factor`), save Stryker JSON (#17) + terminal capture.
- Cross-run differ: two Stryker JSONs → score delta, per-mutant status transitions, per-operator wall-time delta. This is the regression detector for every later perf/accuracy change.

**#9 Adaptive timeout calibration (biggest accuracy lever)**
- Replace pure static budget (`runner.rb:47`: `map.time_for(ids) * factor + floor`) with observed-ratio scaling: first N completed workers report actual/estimated wall-time ratio; Scheduler scales remaining budgets by the running ratio (clamped, e.g. 0.5×–4×).
- Touches `Scheduler` (`lib/active_mutator/scheduler.rb`) + `WorkItem`. TDD anchor: fake clock/scheduler specs — N fast completions shrink later budgets, N slow ones grow them, serial lane keeps `browser_boot_seconds` additive.
- Acceptance: bench harness shows fewer false timeouts at high `--jobs` with no new false kills (this is why #21 lands first).

**#11 Incremental baseline blind spot**
- Problem: delta refresh (`lib/active_mutator/baseline_delta.rb`) re-runs examples that *currently* cover a changed file; an unchanged spec that *starts* covering the edit is invisible until the next full baseline.
- Phase-start design spike (timeboxed 1 day): candidate = also re-run examples whose spec file `require`s / references the changed constant (cheap static heuristic), vs. periodic partial re-baseline of the N oldest coverage entries. Pick via bench-harness measurement; then TDD.
- Interim: README already documents the symptom; ensure `--force-baseline` guidance is prominent.

---

# Phase 5 — Mutation coverage expansion (#4, #5, #3, #6, #2 — in that order)

**#4 Heredoc mutation** — `lib/active_mutator/operators/literal.rb` currently skips heredocs. Mutate the body content range (Prism heredoc content location) instead of the node span. TDD anchor: fixture with `<<~SQL` heredoc; mutant replaces body, splice output re-parses.

**#5 Enumerable call-swap pack** — extend `lib/active_mutator/operators/call_swap.rb`. Candidates: `detect`, `sum`, `sort` ordering, `take`/`drop`, `all?`/`any?`, `find_index`. Each swap gets a one-directional design note (mirroring the existing map→each reasoning) to avoid equivalent-mutant noise; the #20 equivalent-rate metric on the bench corpus is the accept/reject gate per swap.

**#3 `class << self` bodies + nested defs** — `subject_finder.rb:30` (empty `visit_singleton_class_node`) and `:44` (no `super` in `visit_def_node`). Singleton bodies: track scope through the singleton, emit `Foo.bar`-style names. Nested defs: own subject identity (e.g. `Foo#outer>inner` — settle naming in phase plan). Verify `Engine#find_def` and `Inserter` handle both (insertion re-evaluates a mutated def — singleton-class context needs care).

**#6 Operator plugin API** — last, once #5 has stabilized the contract. Public registration point (the `Operators::Base.inherited` registry at `operators/base.rb:4-9` already exists — formalize it), docs, stability policy for `Edit` + node interfaces, config-file key (`operators:` require list) from Phase 3. Graduation gate documented: new operators must clear an equivalent-rate ceiling on the bench corpus.

**#2 Class-level code (macros, constants, DSL blocks)** — biggest item; needs a different insertion strategy (reload whole class in the fork instead of re-evaluating one def). Phase-start design doc required; treat as its own sub-project. If it balloons, split to Phase 5b rather than blocking #6.

---

# Phase 6 — Defer/close decisions (#15, #10, #12, #16)

- [ ] **#16 Windows:** close as won't-fix (fork-based isolation is architectural). README platform note.
- [ ] **#12 minitest:** keep open, milestone "post-1.x". Re-estimate after Phase 5 (coverage map + kill pipeline are already framework-agnostic; the RSpec-specific surface is Baseline hooks + Worker).
- [ ] **#15 watch/daemon mode:** keep open; re-evaluate after Phase 4 (#9's scheduler changes and the incremental baseline work are prerequisites).
- [ ] **#10 browser pooling:** keep open; write findings from payint system-spec dogfood runs into the issue (serial-lane wall-time data from the dogfood log) so a future design starts from measurements.

---

## Self-review notes

- Every open issue maps to a phase (1–22 covered; #13/#14/#16 resolve as decisions).
- Phase 1 tasks contain complete test + implementation code; Phases 2–6 are specs for their own phase-start plans, per the writing-plans scope check.
- Naming consistency: `Config` fields introduced (`exclude`, `max_mutants`, `debug_plan`) are used with identical names in CLI, Runner, and specs.
- Dependency order verified: #17 before #19/#13-decision; #21 before #9/#11; #5+#20 before #6.
