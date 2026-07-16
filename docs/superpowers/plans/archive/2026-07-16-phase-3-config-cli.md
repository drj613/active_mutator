# Phase 3: Config File, --fail-at, and CLI Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.active_mutator.yml` project config file layered under CLI flags, add `--fail-at SCORE` as an opt-in score-gate relaxation, fix #23 (positional file paths silently match nothing), and fix #24 (`--accept-survivors` on a scoped run clobbers out-of-scope ledger entries). Closes #22, #23, #24.

**Architecture:** A new `ConfigFile` class loads and validates `.active_mutator.yml` from the project root; `CLI.parse` merges it into the option defaults *before* OptionParser runs, so flags naturally override file values. `Runner#exit_code` gains the score-gate branch. `Runner#discover_subjects` learns to treat positional args that are files as files and to error on nonexistent paths. `AcceptedLedger#accept!` gains a prune scope: it only deletes entries whose file was fully scanned in the current run, and the Runner only supplies that scope on runs with no subject-level filtering.

**Tech Stack:** Ruby 3.2+, Psych (stdlib YAML), RSpec, existing active_mutator internals (`Config` Data class, `AtomicFile`, `Fingerprint`).

---

## Critical worker constraints (apply to EVERY task)

- **NEVER modify `.active_mutator_accepted.json`.** The acceptance ledger is controller-only state. If a self-mutation run reports survivors you believe are equivalent, STOP and report back — do not run `--accept-survivors`.
- **Self-mutation gate:** every task ends with `bundle exec exe/active_mutator lib --changed` exiting 0. If survivors appear, kill them with tests before finishing (or report as blocked if you believe they are equivalent).
- Run plain specs with `bundle exec rspec`. Integration/e2e specs are env-gated and not needed per-task.
- Commit after each green step per the plan.

## Context for implementers

- `ActiveMutator::Config` is a `Data.define` in `lib/active_mutator/config.rb`; adding a member requires updating every `Config.new` call in specs (there is a spec helper pattern — check `spec/` for how Config instances get built; most specs build options hashes through `CLI.parse` or a helper).
- `ActiveMutator::Error` exists (see `lib/active_mutator.rb`); `CLI.run` rescues `OptionParser::ParseError, Error` and returns exit code 2.
- `CLI.parse` (lib/active_mutator/cli.rb) builds an `options` hash of defaults, mutates it in OptionParser callbacks, and finishes with `Config.new(paths: paths, root: Dir.pwd, **options)`.
- `Fingerprint#file` is root-relative (`m.subject.file.delete_prefix("#{root}/")` — see lib/active_mutator/fingerprint.rb). Subject `#file` is absolute.
- `AcceptedLedger` (lib/active_mutator/accepted_ledger.rb): `accept!(new_fingerprints, all_current_fingerprints)` currently unions then prunes to fingerprints seen in the current run — this is bug #24.
- `Runner#discover_subjects` (lib/active_mutator/runner.rb) globs every positional path as a directory — this is bug #23.

---

### Task 1: ConfigFile loader

**Files:**
- Create: `lib/active_mutator/config_file.rb`
- Modify: `lib/active_mutator.rb` (add require, alphabetical-ish with the others, before `cli`)
- Test: `spec/active_mutator/config_file_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
require "spec_helper"

RSpec.describe ActiveMutator::ConfigFile do
  let(:root) { Dir.mktmpdir }
  after { FileUtils.remove_entry(root) }

  def write_config(yaml)
    File.write(File.join(root, ".active_mutator.yml"), yaml)
  end

  it "returns an empty hash when no config file exists" do
    expect(described_class.load(root)).to eq({})
  end

  it "loads recognized keys as symbol-keyed options" do
    write_config(<<~YAML)
      jobs: 4
      format: stryker-json
      timeout_factor: 6.5
      timeout_floor: 5
      browser_boot_seconds: 20
      fail_at: 90
      exclude:
        - lib/generated
      serial_patterns:
        - spec/system/
      requires:
        - config/boot.rb
      preload_helper: spec/fast_helper.rb
    YAML
    expect(described_class.load(root)).to eq(
      jobs: 4, format: :stryker_json, timeout_factor: 6.5, timeout_floor: 5.0,
      browser_boot_seconds: 20.0, fail_at: 90.0, exclude: ["lib/generated"],
      serial_patterns: ["spec/system/"], requires: ["config/boot.rb"],
      preload_helper: "spec/fast_helper.rb"
    )
  end

  it "maps preload_helper: false to :none" do
    write_config("preload_helper: false\n")
    expect(described_class.load(root)).to eq(preload_helper: :none)
  end

  it "raises on unknown keys" do
    write_config("job: 4\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /unknown config key: job/)
  end

  it "raises on wrong types" do
    write_config("jobs: fast\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /jobs/)
  end

  it "raises on an invalid format value" do
    write_config("format: xml\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /format/)
  end

  it "raises when the file is not a YAML mapping" do
    write_config("- just\n- a list\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /mapping/)
  end

  it "raises on unparseable YAML" do
    write_config("jobs: [unclosed\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /\.active_mutator\.yml/)
  end

  it "treats an empty file as no config" do
    write_config("")
    expect(described_class.load(root)).to eq({})
  end
end
```

- [ ] **Step 2: Run it, verify failure**

Run: `bundle exec rspec spec/active_mutator/config_file_spec.rb`
Expected: FAIL, `uninitialized constant ActiveMutator::ConfigFile`

- [ ] **Step 3: Implement**

```ruby
require "yaml"

module ActiveMutator
  # Project config file, layered UNDER CLI flags: CLI.parse seeds its option
  # defaults from this before OptionParser runs, so any flag given on the
  # command line wins. Strict on unknown keys and types — a typo silently
  # ignored would be a config that silently doesn't apply.
  class ConfigFile
    FILENAME = ".active_mutator.yml"

    FORMATS = %w[terminal json stryker-json github].freeze

    # key => validator (returns coerced value or raises Error)
    KEYS = {
      "jobs" => :integer,
      "format" => :format,
      "timeout_factor" => :number,
      "timeout_floor" => :number,
      "browser_boot_seconds" => :number,
      "fail_at" => :number,
      "exclude" => :string_list,
      "serial_patterns" => :string_list,
      "requires" => :string_list,
      "preload_helper" => :preload_helper
    }.freeze

    def self.load(root)
      path = File.join(root, FILENAME)
      return {} unless File.exist?(path)

      data = parse(path)
      return {} if data.nil?
      raise Error, "#{FILENAME}: top level must be a mapping" unless data.is_a?(Hash)

      data.to_h do |key, value|
        validator = KEYS[key] or raise Error, "#{FILENAME}: unknown config key: #{key}"
        [key.to_sym, coerce(key, validator, value)]
      end
    end

    def self.parse(path)
      YAML.safe_load_file(path)
    rescue Psych::SyntaxError => e
      raise Error, "#{FILENAME}: #{e.message}"
    end

    def self.coerce(key, validator, value)
      case validator
      when :integer
        raise Error, "#{FILENAME}: #{key} must be an integer" unless value.is_a?(Integer)
        value
      when :number
        raise Error, "#{FILENAME}: #{key} must be a number" unless value.is_a?(Numeric)
        value.to_f
      when :format
        unless FORMATS.include?(value)
          raise Error, "#{FILENAME}: format must be one of #{FORMATS.join(", ")}"
        end
        value.tr("-", "_").to_sym
      when :string_list
        unless value.is_a?(Array) && value.all?(String)
          raise Error, "#{FILENAME}: #{key} must be a list of strings"
        end
        value
      when :preload_helper
        return :none if value == false
        raise Error, "#{FILENAME}: preload_helper must be a path or false" unless value.is_a?(String)
        value
      end
    end
  end
end
```

Add to `lib/active_mutator.rb`, next to the other requires (before `cli`):

```ruby
require_relative "active_mutator/config_file"
```

- [ ] **Step 4: Run spec, verify pass**

Run: `bundle exec rspec spec/active_mutator/config_file_spec.rb`
Expected: PASS

- [ ] **Step 5: Full suite + self-mutation gate**

Run: `bundle exec rspec` then `bundle exec exe/active_mutator lib --changed`
Expected: both exit 0. Kill any survivors with additional specs (likely candidates: each raise branch in `coerce`, the `return {} if data.nil?` line, the `tr` call).

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/config_file.rb lib/active_mutator.rb spec/active_mutator/config_file_spec.rb
git commit -m "feat: .active_mutator.yml project config file loader (#22)"
```

---

### Task 2: Layer config file under CLI flags; add fail_at to Config

**Files:**
- Modify: `lib/active_mutator/cli.rb`
- Modify: `lib/active_mutator/config.rb`
- Test: `spec/active_mutator/cli_spec.rb` (extend)

- [ ] **Step 1: Add `fail_at` to Config**

In `lib/active_mutator/config.rb`, add `:fail_at` to the `Data.define` list. Then run `bundle exec rspec` — fix any spec that constructs `Config.new` with every member explicitly (add `fail_at: nil`).

- [ ] **Step 2: Write failing CLI specs**

Append to `spec/active_mutator/cli_spec.rb` (adapt to the file's existing structure — it already stubs/isolates `Dir.pwd`; follow the established pattern for building parse calls):

```ruby
describe "config file layering" do
  around do |ex|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { ex.run }
    end
  end

  it "seeds defaults from .active_mutator.yml" do
    File.write(".active_mutator.yml", "jobs: 3\nfail_at: 85\n")
    config = described_class.parse([])
    expect(config.jobs).to eq(3)
    expect(config.fail_at).to eq(85.0)
  end

  it "lets CLI flags override file values" do
    File.write(".active_mutator.yml", "jobs: 3\nformat: json\n")
    config = described_class.parse(["--jobs", "7", "--format", "terminal"])
    expect(config.jobs).to eq(7)
    expect(config.format).to eq(:terminal)
  end

  it "lets --serial-pattern replace file-provided serial_patterns" do
    File.write(".active_mutator.yml", "serial_patterns:\n  - spec/system/\n")
    config = described_class.parse(["--serial-pattern", "spec/browser/"])
    expect(config.serial_patterns).to eq(["spec/browser/"])
  end

  it "surfaces config file errors as exit code 2 via run" do
    File.write(".active_mutator.yml", "bogus_key: 1\n")
    expect { @code = described_class.run([]) }.to output(/unknown config key/).to_stderr
    expect(@code).to eq(2)
  end

  it "works with no config file present" do
    expect(described_class.parse([]).fail_at).to be_nil
  end
end
```

- [ ] **Step 3: Run, verify failure**

Run: `bundle exec rspec spec/active_mutator/cli_spec.rb`
Expected: FAIL (`fail_at` unknown / file not consulted)

- [ ] **Step 4: Implement layering in CLI.parse**

In `CLI.parse`, after the `options` defaults hash literal, add `fail_at: nil` to the defaults and merge the file config over the defaults before OptionParser runs:

```ruby
options[:fail_at] = nil unless options.key?(:fail_at)  # (or just add fail_at: nil to the literal)
options.merge!(ConfigFile.load(Dir.pwd))
```

Concretely: add `fail_at: nil` inside the defaults literal, then immediately after the literal:

```ruby
      options.merge!(ConfigFile.load(Dir.pwd))
```

Note: file-provided `serial_patterns` must still be replaceable by the first `--serial-pattern` flag — the existing `serial_patterns_replaced` mechanism already does this (first flag use empties the array), no change needed. Verify with the spec.

- [ ] **Step 5: Run specs, verify pass**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 6: Self-mutation gate**

Run: `bundle exec exe/active_mutator lib --changed`
Expected: exit 0, kill survivors with specs if not.

- [ ] **Step 7: Commit**

```bash
git add lib/active_mutator/cli.rb lib/active_mutator/config.rb spec/active_mutator/cli_spec.rb
git commit -m "feat: layer .active_mutator.yml under CLI flags (#22)"
```

---

### Task 3: --fail-at score gate

**Decision (already made, do not relitigate):** default behavior stays strict — any unaccepted survivor exits 1. `--fail-at SCORE` is an explicit opt-in relaxation for gradual adoption on legacy suites: exit 0 as long as the mutation score is >= SCORE, even with survivors. Score formula matches the reporter: `(killed + timeout) / (killed + timeout + survived) * 100`.

**Files:**
- Modify: `lib/active_mutator/cli.rb` (flag)
- Modify: `lib/active_mutator/runner.rb` (`exit_code`)
- Test: `spec/active_mutator/cli_spec.rb`, `spec/active_mutator/runner_spec.rb`

- [ ] **Step 1: Write failing specs**

CLI spec:

```ruby
it "parses --fail-at as a float" do
  expect(described_class.parse(["--fail-at", "92.5"]).fail_at).to eq(92.5)
end

it "rejects --fail-at outside 0..100" do
  expect { described_class.parse(["--fail-at", "101"]) }
    .to raise_error(OptionParser::InvalidArgument)
end
```

Runner spec (follow the existing runner_spec pattern for building results — there are helpers/`Result.new(mutation:, status:, details:)` usages already; a stub mutation is fine since exit_code only reads status):

```ruby
describe "#exit_code with fail_at" do
  def result(status) = ActiveMutator::Result.new(mutation: nil, status: status, details: nil)

  def runner(fail_at:)
    config = build_config(fail_at: fail_at) # use the spec file's existing config-builder helper
    described_class.new(config, reporter: fake_reporter) # match existing pattern
  end

  it "still exits 1 on survivors when fail_at is nil" do
    expect(runner(fail_at: nil).exit_code([result(:killed), result(:survived)])).to eq(1)
  end

  it "exits 0 when score meets the threshold" do
    results = Array.new(9) { result(:killed) } + [result(:survived)]  # 90.0
    expect(runner(fail_at: 90.0).exit_code(results)).to eq(0)
  end

  it "exits 1 when score is below the threshold" do
    results = Array.new(8) { result(:killed) } + [result(:survived), result(:survived)]  # 80.0
    expect(runner(fail_at: 90.0).exit_code(results)).to eq(1)
  end

  it "counts timeouts as detected" do
    results = [result(:timeout)] * 9 + [result(:survived)]  # 90.0
    expect(runner(fail_at: 90.0).exit_code(results)).to eq(0)
  end

  it "exits 0 with no survivors regardless of threshold" do
    expect(runner(fail_at: 100.0).exit_code([result(:uncovered)])).to eq(0)
  end
end
```

- [ ] **Step 2: Run, verify failure**

Run: `bundle exec rspec spec/active_mutator/cli_spec.rb spec/active_mutator/runner_spec.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

CLI flag (in the OptionParser block):

```ruby
o.on("--fail-at SCORE", Float, "Exit 0 if mutation score >= SCORE even with survivors (default: any survivor fails)") do |v|
  raise OptionParser::InvalidArgument, "--fail-at must be within 0..100" unless (0..100).cover?(v)
  options[:fail_at] = v
end
```

Runner:

```ruby
def exit_code(results)
  survived = results.count { |r| r.status == :survived }
  return 0 if survived.zero?
  return 1 unless @config.fail_at

  detected = results.count { |r| %i[killed timeout].include?(r.status) }
  score = detected * 100.0 / (detected + survived)
  score >= @config.fail_at ? 0 : 1
end
```

- [ ] **Step 4: Run specs, verify pass**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 5: Self-mutation gate**

Run: `bundle exec exe/active_mutator lib --changed`
Expected: exit 0. Likely survivors to pre-empt with specs: `>=` → `>` on the threshold comparison (add an exactly-at-threshold spec — the 90.0 ones above cover it), `100.0` literal, `survived.zero?` guard.

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/cli.rb lib/active_mutator/runner.rb spec/active_mutator/cli_spec.rb spec/active_mutator/runner_spec.rb
git commit -m "feat: --fail-at SCORE opt-in score gate (#22)"
```

---

### Task 4: Fix #23 — positional file paths

**Behavior:** a positional arg that is a file is used directly; a directory is globbed as today; anything else raises `ActiveMutator::Error` (exit 2 via CLI rescue). No more vacuous green.

**Files:**
- Modify: `lib/active_mutator/runner.rb` (`discover_subjects` + new private `expand_path_arg`)
- Test: `spec/active_mutator/runner_spec.rb`

- [ ] **Step 1: Write failing specs**

Follow runner_spec's existing discovery-test pattern (it builds temp roots with real files for discovery specs; reuse that helper). Cases:

```ruby
describe "positional path arguments" do
  # inside the existing discovery spec context with a tmp root containing
  # lib/foo.rb (defining Foo#bar) and lib/sub/baz.rb (defining Baz#qux)

  it "accepts a direct file path" do
    subjects = runner_with(paths: ["lib/foo.rb"]).send(:discover_subjects)
    expect(subjects.map(&:name)).to eq(["Foo#bar"])
  end

  it "still globs directories" do
    subjects = runner_with(paths: ["lib"]).send(:discover_subjects)
    expect(subjects.map(&:name)).to contain_exactly("Foo#bar", "Baz#qux")
  end

  it "raises on a nonexistent path" do
    expect { runner_with(paths: ["lib/nope.rb"]).send(:discover_subjects) }
      .to raise_error(ActiveMutator::Error, %r{lib/nope\.rb})
  end

  it "applies --exclude to directly named files" do
    subjects = runner_with(paths: ["lib/foo.rb"], exclude: ["lib/foo.rb"]).send(:discover_subjects)
    expect(subjects).to be_empty
  end
end
```

- [ ] **Step 2: Run, verify failure**

Run: `bundle exec rspec spec/active_mutator/runner_spec.rb`
Expected: FAIL (file path yields 0 subjects today; nonexistent path yields [] not an error)

- [ ] **Step 3: Implement**

In `discover_subjects`, replace

```ruby
        .flat_map { |p| Dir[File.join(@config.root, p, "**", "*.rb")] }
```

with

```ruby
        .flat_map { |p| expand_path_arg(p) }
```

and add the private method:

```ruby
    # Positional args may be files or directories. Anything else is an error:
    # a mistyped path that silently matched nothing produced a false green
    # (0 subjects, exit 0) — see #23.
    def expand_path_arg(path)
      full = File.expand_path(path, @config.root)
      if File.file?(full)
        [full]
      elsif Dir.exist?(full)
        Dir[File.join(full, "**", "*.rb")]
      else
        raise Error, "no such file or directory: #{path}"
      end
    end
```

Note `default_paths` already filters to existing dirs, so the error branch only fires for user-typed args — correct.

- [ ] **Step 4: Run specs, verify pass**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 5: Self-mutation gate**

Run: `bundle exec exe/active_mutator lib --changed`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/runner.rb spec/active_mutator/runner_spec.rb
git commit -m "fix: positional file paths and nonexistent paths (#23)"
```

---

### Task 5: Fix #24 — scoped --accept-survivors clobbers ledger

**Behavior:** `accept!` always unions new acceptances in. Pruning of no-longer-matching entries happens only for entries whose file was *fully scanned* this run: the Runner passes a prune scope (root-relative file list) only when there is no subject-level narrowing (`--subject`, `--since`/`--changed`, `--max-mutants` all absent). With narrowing active, prune scope is nil and nothing is deleted. `warn_stale` gets the same scoping so scoped runs don't spam stale warnings about out-of-scope entries.

**Files:**
- Modify: `lib/active_mutator/accepted_ledger.rb`
- Modify: `lib/active_mutator/runner.rb`
- Test: `spec/active_mutator/accepted_ledger_spec.rb`, `spec/active_mutator/runner_spec.rb`

- [ ] **Step 1: Write failing ledger specs**

Extend `spec/active_mutator/accepted_ledger_spec.rb` (reuse its fingerprint-builder helpers):

```ruby
describe "#accept! prune scoping" do
  # fp(file:, subject:, ...) helper per existing spec

  it "keeps out-of-scope entries when scanned_files is nil" do
    ledger = build_ledger(entries: [fp(file: "lib/other.rb", subject: "Other#x")])
    ledger.accept!([fp(file: "lib/a.rb", subject: "A#y")],
                   [fp(file: "lib/a.rb", subject: "A#y")], scanned_files: nil)
    expect(reload_entries).to contain_exactly(
      fp(file: "lib/other.rb", subject: "Other#x"), fp(file: "lib/a.rb", subject: "A#y")
    )
  end

  it "prunes stale entries only within scanned files" do
    stale_in_scope   = fp(file: "lib/a.rb", subject: "A#gone")
    stale_out_scope  = fp(file: "lib/other.rb", subject: "Other#x")
    current          = fp(file: "lib/a.rb", subject: "A#y")
    ledger = build_ledger(entries: [stale_in_scope, stale_out_scope, current])
    ledger.accept!([], [current], scanned_files: ["lib/a.rb"])
    expect(reload_entries).to contain_exactly(stale_out_scope, current)
  end
end

describe "#stale_entries with scanned_files" do
  it "only reports staleness within scanned files" do
    ledger = build_ledger(entries: [fp(file: "lib/a.rb", subject: "A#gone"),
                                    fp(file: "lib/other.rb", subject: "Other#x")])
    stale = ledger.stale_entries([], scanned_files: ["lib/a.rb"])
    expect(stale.map(&:subject)).to eq(["A#gone"])
  end

  it "reports nothing when scanned_files is nil (scoped run)" do
    ledger = build_ledger(entries: [fp(file: "lib/a.rb", subject: "A#gone")])
    expect(ledger.stale_entries([], scanned_files: nil)).to be_empty
  end
end
```

And runner specs asserting the wiring:

```ruby
describe "accept-survivors prune scope" do
  it "passes scanned files on an unfiltered run" # ledger receives scanned_files: array of root-relative files
  it "passes nil scanned_files when --subject is set"
  it "passes nil scanned_files when --since is set"
  it "passes nil scanned_files when --max-mutants is set"
end
```

Implement these with an instance_double of AcceptedLedger and `expect(ledger).to have_received(:accept!).with(anything, anything, scanned_files: ...)`, following runner_spec's existing stubbing style for ledger interactions.

- [ ] **Step 2: Run, verify failure**

Run: `bundle exec rspec spec/active_mutator/accepted_ledger_spec.rb spec/active_mutator/runner_spec.rb`
Expected: FAIL (accept! doesn't take scanned_files)

- [ ] **Step 3: Implement ledger side**

```ruby
    # Entries outside the scanned files can't be judged by this run, so they
    # are never stale here. scanned_files: nil means "no file was fully
    # scanned" (subject-level filtering active) — union only, prune nothing.
    # See #24: a scoped accept run once deleted every out-of-scope entry.
    def stale_entries(all_current_fingerprints, scanned_files:)
      return [] if scanned_files.nil?

      current = all_current_fingerprints.to_set
      scanned = scanned_files.to_set
      @entries.reject { |e| current.include?(e) || !scanned.include?(e.file) }
    end

    def accept!(new_fingerprints, all_current_fingerprints, scanned_files:)
      stale = stale_entries(all_current_fingerprints, scanned_files: scanned_files).to_set
      @entries = (@entries + new_fingerprints).uniq.reject { |e| stale.include?(e) }
      AtomicFile.write(@path, JSON.pretty_generate(@entries.map(&:to_h)))
      nil
    end
```

- [ ] **Step 4: Implement runner side**

In `Runner#call`, compute the prune scope after discovery and thread it through:

```ruby
      subjects = discover_subjects
      scanned_files = prune_scope(subjects)
```

then `warn_stale(ledger, fingerprints.values, scanned_files)` and `accept_survivors!(ledger, results, fingerprints, scanned_files)`. New private method:

```ruby
    # Only a run with no subject-level narrowing has fully scanned a file;
    # anything narrower must not prune (or warn about) out-of-scope entries.
    def prune_scope(subjects)
      return nil if @config.subject_filter || @config.since || @config.max_mutants

      subjects.map { |s| s.file.delete_prefix("#{@config.root}/") }.uniq
    end
```

Update `warn_stale` and `accept_survivors!` signatures to pass `scanned_files:` through. Note `--max-mutants` truncates *mutations*, not subjects, so its fingerprint set is incomplete — that's why it disables pruning.

- [ ] **Step 5: Run specs, verify pass**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 6: Self-mutation gate**

Run: `bundle exec exe/active_mutator lib --changed`
Expected: exit 0. Likely survivors: the `||` chain in `prune_scope` (one spec per branch above kills them), `uniq`, `reject` vs `select` polarity in `stale_entries`.

- [ ] **Step 7: Commit**

```bash
git add lib/active_mutator/accepted_ledger.rb lib/active_mutator/runner.rb spec/active_mutator/accepted_ledger_spec.rb spec/active_mutator/runner_spec.rb
git commit -m "fix: scoped --accept-survivors no longer clobbers out-of-scope ledger entries (#24)"
```

---

### Task 6: Docs + dogfood

**Files:**
- Modify: `README.md`
- Modify: `docs/skills/mutation-check.md` (mention config file + fail-at if it documents flags; skip if not)
- Modify: `docs/dogfood-log.md`

- [ ] **Step 1: README updates**

- Flags table: add `--fail-at SCORE` row ("none (strict)" default, "exit 0 if score >= SCORE even with survivors — opt-in relaxation for gradual adoption").
- New `## Configuration file` section after `## Flags`:

```markdown
## Configuration file

Put team-wide settings in `.active_mutator.yml` at the project root; CLI
flags override file values. Recognized keys: `jobs`, `format`,
`timeout_factor`, `timeout_floor`, `browser_boot_seconds`, `fail_at`,
`exclude`, `serial_patterns`, `requires`, `preload_helper` (a path, or
`false` to skip preload). Unknown keys are an error.

```yaml
# .active_mutator.yml
jobs: 4
exclude:
  - lib/generated
serial_patterns:
  - spec/system/
fail_at: 90   # legacy suite: gate on score instead of zero-survivors
```
```

- Usage section: note `active_mutator app/models/document.rb` now works (file path) and that mistyped paths error instead of passing.
- Update exit-code text: "Exit code is 1 if unaccepted survivors exist (or, with `--fail-at`, if the score is below the threshold)".
- Known limits: remove nothing; unchanged.

- [ ] **Step 2: Dogfood on this repo**

Run and record in `docs/dogfood-log.md` (follow existing row format):
1. `bundle exec exe/active_mutator lib/active_mutator/config_file.rb` — file-path positional arg exercising #23 fix for real.
2. Write a temporary `.active_mutator.yml` with `jobs: 2`, run `bundle exec exe/active_mutator lib/active_mutator/config_file.rb`, confirm it applies (2 workers), then DELETE the yml (do not commit it).
3. `bundle exec exe/active_mutator lib/nope.rb` — confirm exit 2 with the error message.

- [ ] **Step 3: Full self-run gate**

Run: `bundle exec rspec && bundle exec exe/active_mutator lib`
Expected: both exit 0 (ledger has 25 accepted entries; do not touch them).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/dogfood-log.md docs/skills/mutation-check.md
git commit -m "docs: config file, --fail-at, path-arg fixes"
```
