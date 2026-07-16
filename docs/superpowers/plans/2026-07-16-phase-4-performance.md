# Phase 4 — Bench Harness, Adaptive Timeouts, Baseline Blind Spot (#21, #9, #11)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a deterministic benchmark harness (#21), replace the purely static timeout budget with runtime-calibrated budgets (#9), and close the incremental baseline's newly-covering-example blind spot for the constant-reference case (#11).

**Architecture:** The harness lives entirely under `bench/` + `bin/` (pure stdlib, never required by the gem's runtime); it runs `exe/active_mutator` against the committed `spec/fixtures/` corpus, records per-stage wall times and mutant counts, and a `ReportDiff` compares two Stryker JSONs for regressions. #9 introduces per-lane `TimeoutCalibrator`s that the `Scheduler` consults at spawn time (deadline) and feeds at reap time (killed forks only, wall time measured against the effective budget the fork ran under), scaling the variable part of each remaining budget by the clamped median utilization; bench cells opt out (`--no-adaptive-timeout`) so the regression gate stays deterministic. #11 extends `BaselineDelta.compute` to also re-run spec files that textually reference a constant defined in a changed source file but currently contribute zero coverage to it.

**Tech Stack:** Ruby (stdlib `json`, `optparse`, `open3`, `fileutils`), Prism, RSpec, fork-based workers. No new gem dependencies anywhere.

**Scope decisions (honest deviations from the issue text):**
- Issue #21 asks for 3–5 SHA-pinned external repos. This plan ships the harness with **two committed fixture targets** (`spec/fixtures/tiny_project` small gem, `spec/fixtures/rails_app` Rails cell) plus first-class support for `git`-type SHA-pinned targets in `bench/targets.json`. Adding external pinned repos afterwards is a data-only edit (one JSON row) requiring network access and a maintainer choice of repos — it needs no code and is deliberately left out so every task here is runnable offline and deterministically. The cross-run differ and matrix runner from the issue are fully implemented.
- Issue #11's residual gap: a spec file that *already partially covers* the changed source and whose *other* examples newly start covering it is still invisible (re-running it wholesale on every edit would regress incremental speed for zero-coverage-growth in the common case). The fix here covers the documented primary case — an unchanged, currently-non-covering spec file that references the changed constant. Nightly `--force-baseline` remains the documented backstop and the docs task updates that language precisely.

---

## Critical worker constraints

- **NEVER modify `.active_mutator_accepted.json`** (the acceptance ledger). If a self-mutation run surfaces a survivor, kill it with a new test — do not accept it.
- **NEVER run `--accept-survivors`.**
- **Every task ends with BOTH gates green before commit:**
  ```bash
  cd /Users/djdjo/Documents/enovis/active_mutator
  bundle exec rspec                              # exit 0
  bundle exec exe/active_mutator lib --changed   # exit 0 (self-mutation gate)
  ```
- **Commit at the end of every task** with the exact `git` commands given in the task. One task = one commit.
- Work on branch `phase-4-performance`. Do not push.

---

## Context for implementers

You have zero prior context. Everything you need is here.

### File map

| Path | Role |
|---|---|
| `lib/active_mutator/runner.rb` | Orchestrator. `#plan_work` (line ~41) builds `WorkItem`s and computes static timeouts. `#call` wires `Scheduler`. |
| `lib/active_mutator/scheduler.rb` | Fork pool. `#spawn` sets `deadline: now + item.timeout`; `#reap` SIGKILLs past-deadline forks and reports `:timeout`. |
| `lib/active_mutator/work_item.rb` | `WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane)` |
| `lib/active_mutator/worker.rb` | Runs inside the fork: RSpec setup → insert mutation → run covering examples. |
| `lib/active_mutator/baseline.rb` | Runs/caches the instrumented baseline. `#coverage_map` dispatches full vs partial refresh via `BaselineDelta`. `#merge_partial!` folds a partial re-run into the cache (drops records for re-run spec files by `"#{rel}["` prefix). |
| `lib/active_mutator/baseline_delta.rb` | `BaselineDelta.compute(old_digests:, new_digests:, coverage_map:, root:)` → `Delta(full, rerun_spec_files, rerun_example_ids, drop_example_ids, drop_source_files)`. |
| `lib/active_mutator/baseline_hooks.rb` | Injected via RUBYOPT into the host suite; records per-example coverage diffs and wall times. |
| `lib/active_mutator/coverage_map.rb` | `#examples_for(file, lines)`, `#time_for(example_ids)` (sum of baseline per-example seconds), `#examples_covering_file(abs)`, `#examples_for_spec_file(rel)`. |
| `lib/active_mutator/config.rb` | `Config = Data.define(...)` — every new field must be added here. |
| `lib/active_mutator/cli.rb` | optparse; defaults hash at top of `.parse`. |
| `lib/active_mutator/config_file.rb` | `.active_mutator.yml` loader; `KEYS` map + `coerce` validators. |
| `lib/active_mutator/reporter/stryker_json.rb` | Writes `.active_mutator/mutation-report.json` (mutation-testing-report-schema v2). |
| `spec/fixtures/tiny_project/` | Committed small-gem fixture (Calculator, planted survivors) used by e2e specs. |
| `spec/fixtures/rails_app/` | Committed minimal Rails fixture used by e2e specs. |
| `spec/e2e/*.rb` | Env-gated (`ACTIVE_MUTATOR_E2E=1`) real-fork end-to-end specs; `ensure_fixture_bundle!` helper installs fixture bundles. |

### Key fact 1 — how timeouts are computed today

`Runner#plan_work`, `lib/active_mutator/runner.rb:54`:

```ruby
timeout = map.time_for(example_ids) * @config.timeout_factor + @config.timeout_floor
timeout += @config.browser_boot_seconds if lane == :serial
```

Defaults: `timeout_factor: 8.0`, `timeout_floor: 10.0`, `browser_boot_seconds: 15.0` (CLI defaults hash). `map.time_for` sums baseline per-example wall times measured **warm and unloaded**; the factor is supposed to absorb parallel-load slowdown and the floor the fork's boot cost. Issue #9: a real 515-mutant Rails run showed the static formula misclassifies slow-but-honest kills as timeouts under parallel load. The Scheduler enforces the deadline in `#spawn` (`deadline: now + item.timeout`) and `#reap`.

### Key fact 2 — how the incremental baseline delta works, and where the blind spot is

`Baseline#coverage_map`: if the cache digests mismatch, `BaselineDelta.compute` classifies each changed file. Changed **spec** file → re-run that whole spec file. Changed **source** file → re-run only the example ids **currently covering any line of that file** (`coverage_map.examples_covering_file`). `Baseline#run_partial!` re-invokes `bundle exec rspec` with those targets and `merge_partial!` drops the obsolete records (re-run spec files are dropped by `"#{rel}["` example-id prefix) and merges the new ones.

**The blind spot (#11, documented at `docs/guides/how-it-works.md:142-158`):** an example in an *unchanged* spec file that only *starts* covering the changed source *because of* the edit (e.g. a shared example now reaching a new branch) is invisible — it wasn't in the currently-covering set, and its spec file didn't change. Result: false `uncovered`/`survived` until the next full baseline. Current recovery: nightly `--force-baseline`.

### Key fact 3 — determinism & fixture invariants

`spec/fixtures/tiny_project` deterministically produces: 2 planted survivors on `Calculator#discount` (`<`→`<=`, `100`→`101`), all `Calculator#eligible?` mutants killed, `Calculator#untested_helper` uncovered (see `spec/e2e/tiny_project_spec.rb`). The bench harness leans on this: mutant statuses on the fixture corpus must be identical run-to-run; only wall times vary.

### Key fact 4 — gates

- e2e specs only run with `ACTIVE_MUTATOR_E2E=1 bundle exec rspec spec/e2e`.
- The self-mutation gate mutates `lib/` only; `bench/` and `bin/` code is out of its scope but you still run the gate every task (it validates any `lib/` change you made).

---

# Task 1 — `Bench::ReportDiff`: cross-run Stryker JSON differ (#21)

**Files:**
- Create: `bench/lib/bench/report_diff.rb`
- Create: `spec/bench/report_diff_spec.rb`

Pure stdlib class. Keyed identity of a mutant across runs: `[file, start line, start column, mutatorName, replacement]`. Output: score per run, score delta, status transitions (list of `[key, from, to]`), mutants only in A / only in B.

- [ ] **Step 1: Write the failing spec**

Create `spec/bench/report_diff_spec.rb`:

```ruby
require_relative "../../bench/lib/bench/report_diff"

RSpec.describe Bench::ReportDiff do
  def mutant(file: "lib/a.rb", line: 3, column: 5, op: "BinaryOperator",
             replacement: "<=", status: "Killed")
    [file, { "mutatorName" => op, "replacement" => replacement, "status" => status,
             "location" => { "start" => { "line" => line, "column" => column },
                             "end" => { "line" => line, "column" => column + 2 } } }]
  end

  def report(mutants)
    files = Hash.new { |h, k| h[k] = { "mutants" => [] } }
    mutants.each { |file, m| files[file]["mutants"] << m }
    { "files" => files }
  end

  it "computes the mutation score of each report (detected / detected + survived)" do
    a = report([mutant(status: "Killed"), mutant(line: 9, status: "Survived"),
                mutant(line: 12, status: "Timeout"), mutant(line: 20, status: "NoCoverage")])
    diff = described_class.new(a, a).call
    expect(diff[:score_a]).to eq(66.67) # 2 detected (Killed+Timeout) / 3 scoreable; NoCoverage excluded
    expect(diff[:score_b]).to eq(66.67)
    expect(diff[:score_delta]).to eq(0.0)
  end

  it "lists status transitions keyed by file/line/column/operator/replacement" do
    a = report([mutant(status: "Killed")])
    b = report([mutant(status: "Timeout")])
    diff = described_class.new(a, b).call
    expect(diff[:transitions]).to eq(
      [{ key: "lib/a.rb:3:5 BinaryOperator <=", from: "Killed", to: "Timeout" }]
    )
  end

  it "reports mutants present in only one run" do
    a = report([mutant, mutant(line: 9)])
    b = report([mutant])
    diff = described_class.new(a, b).call
    expect(diff[:only_in_a]).to eq(["lib/a.rb:9:5 BinaryOperator <="])
    expect(diff[:only_in_b]).to eq([])
  end

  it "has no transitions when statuses match" do
    a = report([mutant, mutant(line: 9, status: "Survived")])
    expect(described_class.new(a, a).call[:transitions]).to eq([])
  end
end
```

- [ ] **Step 2: Run, expect FAIL**

```bash
bundle exec rspec spec/bench/report_diff_spec.rb
```
Expected: LoadError (`cannot load such file .../bench/lib/bench/report_diff`).

- [ ] **Step 3: Implement**

Create `bench/lib/bench/report_diff.rb`:

```ruby
# Compares two mutation-testing-report-schema v2 JSONs (parsed Hashes).
# Pure stdlib; never required by the gem's runtime.
module Bench
  class ReportDiff
    DETECTED = %w[Killed Timeout].freeze
    SCOREABLE = %w[Killed Timeout Survived RuntimeError].freeze

    def initialize(report_a, report_b)
      @a = index(report_a)
      @b = index(report_b)
    end

    def call
      shared = @a.keys & @b.keys
      transitions = shared.filter_map do |key|
        from, to = @a[key], @b[key]
        { key: key, from: from, to: to } if from != to
      end
      {
        score_a: score(@a), score_b: score(@b),
        score_delta: (score(@b) - score(@a)).round(2),
        transitions: transitions.sort_by { |t| t[:key] },
        only_in_a: (@a.keys - @b.keys).sort,
        only_in_b: (@b.keys - @a.keys).sort
      }
    end

    private

    # {key => status}. Key must be stable across runs: location + operator + replacement.
    def index(report)
      report.fetch("files").flat_map do |file, entry|
        entry.fetch("mutants").map do |m|
          start = m.fetch("location").fetch("start")
          key = "#{file}:#{start["line"]}:#{start["column"]} " \
                "#{m["mutatorName"]} #{m["replacement"]}"
          [key, m.fetch("status")]
        end
      end.to_h
    end

    def score(indexed)
      statuses = indexed.values.select { |s| SCOREABLE.include?(s) }
      return 0.0 if statuses.empty?

      detected = statuses.count { |s| DETECTED.include?(s) }
      (detected * 100.0 / statuses.size).round(2)
    end
  end
end
```

- [ ] **Step 4: Run, expect PASS**

```bash
bundle exec rspec spec/bench/report_diff_spec.rb
```
Expected: 4 examples, 0 failures. Note the score spec: 2 detected / 3 scoreable = 66.67 (NoCoverage excluded from the denominator, matching Stryker's score definition).

- [ ] **Step 5: Full gates**

```bash
bundle exec rspec
bundle exec exe/active_mutator lib --changed
```
Expected: both exit 0 (no `lib/` changes yet, so the gate is a fast no-op pass).

- [ ] **Step 6: Commit**

```bash
git add bench/lib/bench/report_diff.rb spec/bench/report_diff_spec.rb
git commit -m "feat(bench): cross-run Stryker report differ

Refs #21"
```

---

# Task 2 — `Bench::Plan`: targets file + cell matrix expansion (#21)

**Files:**
- Create: `bench/targets.json`
- Create: `bench/lib/bench/plan.rb`
- Create: `spec/bench/plan_spec.rb`

`bench/targets.json` declares targets; `Bench::Plan` expands each target's flag matrix into runnable cells. Target types: `"path"` (committed fixture, relative to repo root) and `"git"` (`url` + `sha`, cloned into `bench/.cache/<name>` — supported now, no default entries; see scope decision in the header).

- [ ] **Step 1: Write the failing spec**

Create `spec/bench/plan_spec.rb`:

```ruby
require "json"
require "tmpdir"
require_relative "../../bench/lib/bench/plan"

RSpec.describe Bench::Plan do
  def write_targets(dir, data)
    path = File.join(dir, "targets.json")
    File.write(path, JSON.generate(data))
    path
  end

  it "expands the jobs x timeout_factor matrix into named cells" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "tiny", "type" => "path", "path" => "spec/fixtures/tiny_project",
          "paths" => ["lib"], "matrix" => { "jobs" => [1, 2], "timeout_factor" => [8.0] } }
      ])
      cells = described_class.load(path).cells
      expect(cells.map(&:id)).to eq(["tiny-jobs1-tf8.0", "tiny-jobs2-tf8.0"])
      expect(cells.first.argv).to eq(
        ["lib", "--jobs", "1", "--timeout-factor", "8.0", "--format", "stryker-json"]
      )
      expect(cells.first.target_name).to eq("tiny")
      expect(cells.first.path).to eq("spec/fixtures/tiny_project")
    end
  end

  it "defaults the matrix to a single cell with no extra flags" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "tiny", "type" => "path", "path" => "spec/fixtures/tiny_project",
          "paths" => ["lib"] }
      ])
      cells = described_class.load(path).cells
      expect(cells.map(&:id)).to eq(["tiny-default"])
      expect(cells.first.argv).to eq(["lib", "--format", "stryker-json"])
    end
  end

  it "rejects unknown target types" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [{ "name" => "x", "type" => "svn" }])
      expect { described_class.load(path) }.to raise_error(/unknown target type/)
    end
  end

  it "carries git url and sha for git targets" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "g", "type" => "git", "url" => "https://example.com/g.git",
          "sha" => "abc123", "paths" => ["lib"] }
      ])
      cells = described_class.load(path).cells
      expect(cells.first.git_url).to eq("https://example.com/g.git")
      expect(cells.first.git_sha).to eq("abc123")
      expect(cells.first.path).to eq("bench/.cache/g")
    end
  end
end
```

- [ ] **Step 2: Run, expect FAIL**

```bash
bundle exec rspec spec/bench/plan_spec.rb
```
Expected: LoadError.

- [ ] **Step 3: Implement**

Create `bench/lib/bench/plan.rb`:

```ruby
require "json"

# Parses bench/targets.json and expands each target's flag matrix into cells.
# Pure stdlib; never required by the gem's runtime.
module Bench
  class Plan
    Cell = Data.define(:id, :target_name, :type, :path, :git_url, :git_sha, :argv)

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def initialize(data)
      @targets = data.fetch("targets")
    end

    def cells
      @targets.flat_map { |t| expand(t) }
    end

    private

    def expand(target)
      type = target.fetch("type")
      raise ArgumentError, "unknown target type: #{type}" unless %w[path git].include?(type)

      path = type == "git" ? File.join("bench/.cache", target.fetch("name")) : target.fetch("path")
      combos(target.fetch("matrix", {})).map do |combo|
        Cell.new(
          id: cell_id(target.fetch("name"), combo),
          target_name: target.fetch("name"),
          type: type,
          path: path,
          git_url: target["url"],
          git_sha: target["sha"],
          argv: target.fetch("paths", []) + flag_argv(combo) + ["--format", "stryker-json"]
        )
      end
    end

    # {"jobs"=>[1,2], "timeout_factor"=>[8.0]} -> [{"jobs"=>1,...}, {"jobs"=>2,...}]
    def combos(matrix)
      matrix.reduce([{}]) do |acc, (flag, values)|
        acc.flat_map { |combo| values.map { |v| combo.merge(flag => v) } }
      end
    end

    def cell_id(name, combo)
      return "#{name}-default" if combo.empty?

      suffix = combo.map { |flag, v| "#{abbrev(flag)}#{v}" }.join("-")
      "#{name}-#{suffix}"
    end

    def abbrev(flag)
      { "jobs" => "jobs", "timeout_factor" => "tf", "timeout_floor" => "floor" }
        .fetch(flag, flag.delete("_"))
    end

    def flag_argv(combo)
      combo.flat_map { |flag, v| ["--#{flag.tr("_", "-")}", v.to_s] }
    end
  end
end
```

- [ ] **Step 4: Run, expect PASS**

```bash
bundle exec rspec spec/bench/plan_spec.rb
```
Expected: 4 examples, 0 failures.

- [ ] **Step 5: Commit the default corpus file**

Create `bench/targets.json`:

```json
{
  "targets": [
    {
      "name": "tiny_project",
      "type": "path",
      "path": "spec/fixtures/tiny_project",
      "paths": ["lib"],
      "matrix": { "jobs": [1, 2] }
    },
    {
      "name": "rails_app",
      "type": "path",
      "path": "spec/fixtures/rails_app",
      "paths": ["app", "lib"],
      "matrix": { "jobs": [2] }
    }
  ]
}
```

- [ ] **Step 6: Full gates**

```bash
bundle exec rspec
bundle exec exe/active_mutator lib --changed
```
Expected: both exit 0.

- [ ] **Step 7: Commit**

```bash
git add bench/lib/bench/plan.rb bench/targets.json spec/bench/plan_spec.rb
git commit -m "feat(bench): targets file and cell matrix expansion

Refs #21"
```

---

# Task 3 — `bin/bench` runner + `bin/bench-diff` (#21)

**Files:**
- Create: `bench/lib/bench/runner.rb`
- Create: `bin/bench` (executable)
- Create: `bin/bench-diff` (executable)
- Create: `spec/bench/runner_spec.rb`
- Modify: `.gitignore` (add `bench/.cache/` and `bench/results/`)

Per cell: prepare the target (git targets: clone + `git checkout <sha>` into `bench/.cache/<name>`; path targets: use in place), `bundle install` once per target, then **two timed stages**: (1) `--force-baseline --max-mutants 0` measures the baseline stage in isolation (`--max-mutants 0` plans zero mutants, so the run is baseline-only); (2) the cell's real argv against the warm cache measures the mutation stage. Save per cell: the Stryker report, captured stdout+stderr, and a `bench.json` summary. The shell-out is isolated in one injectable lambda so the orchestration logic is unit-testable without forking real runs.

**Determinism contract:** `bin/bench-diff` exit 0 is a regression gate, so cell runs must be status-deterministic. The `--no-adaptive-timeout` flag does not exist until Task 7; the moment it does, Task 7 Step 4 makes `Bench::Plan` append it to every cell by default (adaptive behavior is then opt-in per matrix row). Until Task 7, static budgets are the only behavior, so the gate is deterministic as-is.

- [ ] **Step 1: Write the failing spec**

Create `spec/bench/runner_spec.rb`:

```ruby
require "json"
require "tmpdir"
require_relative "../../bench/lib/bench/plan"
require_relative "../../bench/lib/bench/runner"

RSpec.describe Bench::Runner do
  def cell(id: "tiny-jobs1", argv: ["lib", "--jobs", "1", "--format", "stryker-json"])
    Bench::Plan::Cell.new(id: id, target_name: "tiny", type: "path",
                          path: "spec/fixtures/tiny_project",
                          git_url: nil, git_sha: nil, argv: argv)
  end

  def fake_exec(log, statuses: Hash.new(true))
    lambda do |argv, chdir:|
      log << { argv: argv, chdir: chdir }
      statuses[argv.join(" ")]
    end
  end

  it "runs baseline stage then mutation stage per cell and writes bench.json" do
    Dir.mktmpdir do |out|
      log = []
      runner = described_class.new(cells: [cell], repo_root: Dir.pwd,
                                   out_dir: out, exec: fake_exec(log))
      # Stub the report copy: the fake exec produces no mutation-report.json.
      allow(runner).to receive(:collect_report)
      runner.call

      mutator_calls = log.select { |c| c[:argv].include?("active_mutator") }
      expect(mutator_calls.size).to eq(2)
      expect(mutator_calls[0][:argv]).to include("--force-baseline", "--max-mutants", "0")
      expect(mutator_calls[1][:argv]).to include("--jobs", "1")
      expect(mutator_calls).to all(include(chdir: end_with("spec/fixtures/tiny_project")))

      summary = JSON.parse(File.read(File.join(out, "tiny-jobs1", "bench.json")))
      expect(summary.keys).to include("cell", "baseline_seconds", "mutation_seconds", "exit_ok")
      expect(summary["cell"]).to eq("tiny-jobs1")
      expect(summary["exit_ok"]).to be(true)
    end
  end

  it "bundle-installs each target once, not per cell" do
    Dir.mktmpdir do |out|
      log = []
      runner = described_class.new(cells: [cell(id: "a"), cell(id: "b")],
                                   repo_root: Dir.pwd, out_dir: out, exec: fake_exec(log))
      allow(runner).to receive(:collect_report)
      runner.call
      installs = log.count { |c| c[:argv][0, 2] == %w[bundle install] }
      expect(installs).to eq(1)
    end
  end

  it "records a failed mutation stage as exit_ok false and keeps going" do
    Dir.mktmpdir do |out|
      log = []
      statuses = Hash.new(true)
      bad = cell(id: "bad", argv: ["lib", "--jobs", "1", "--format", "stryker-json"])
      exec = lambda do |argv, chdir:|
        log << { argv: argv, chdir: chdir }
        # Fail only the real mutation stage (no --force-baseline in argv).
        !(argv.include?("active_mutator") && !argv.include?("--force-baseline"))
      end
      runner = described_class.new(cells: [bad, cell(id: "good")],
                                   repo_root: Dir.pwd, out_dir: out, exec: exec)
      allow(runner).to receive(:collect_report)
      runner.call
      bad_summary = JSON.parse(File.read(File.join(out, "bad", "bench.json")))
      good_summary = JSON.parse(File.read(File.join(out, "good", "bench.json")))
      expect(bad_summary["exit_ok"]).to be(false)
      expect(good_summary["exit_ok"]).to be(true)
    end
  end
end
```

- [ ] **Step 2: Run, expect FAIL**

```bash
bundle exec rspec spec/bench/runner_spec.rb
```
Expected: LoadError.

- [ ] **Step 3: Implement**

Create `bench/lib/bench/runner.rb`:

```ruby
require "fileutils"
require "json"

# Executes plan cells against fixture/pinned targets. Pure stdlib;
# never required by the gem's runtime.
module Bench
  class Runner
    def initialize(cells:, repo_root:, out_dir:, exec: nil, clock: nil)
      @cells = cells
      @repo_root = repo_root
      @out_dir = out_dir
      @exec = exec || method(:system_exec)
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @prepared = {}
    end

    def call
      @cells.each do |cell|
        target_dir = prepare_target(cell)
        run_cell(cell, target_dir)
      end
    end

    private

    def prepare_target(cell)
      dir = File.expand_path(cell.path, @repo_root)
      return @prepared[cell.target_name] if @prepared.key?(cell.target_name)

      if cell.type == "git"
        unless Dir.exist?(dir)
          FileUtils.mkdir_p(File.dirname(dir))
          @exec.call(["git", "clone", cell.git_url, dir], chdir: @repo_root) ||
            raise("clone failed: #{cell.git_url}")
        end
        @exec.call(["git", "checkout", cell.git_sha], chdir: dir) ||
          raise("checkout failed: #{cell.git_sha}")
      end
      @exec.call(%w[bundle install], chdir: dir) || raise("bundle install failed in #{dir}")
      # Cold cache per target so the measured baseline stage is a real full run.
      FileUtils.rm_rf(File.join(dir, ".active_mutator"))
      @prepared[cell.target_name] = dir
    end

    def run_cell(cell, target_dir)
      cell_dir = File.join(@out_dir, cell.id)
      FileUtils.mkdir_p(cell_dir)
      mutator = File.expand_path("exe/active_mutator", @repo_root)

      baseline_seconds, = timed do
        @exec.call(["bundle", "exec", mutator, *cell.argv, "--force-baseline", "--max-mutants", "0"],
                   chdir: target_dir)
      end
      mutation_seconds, ok = timed do
        @exec.call(["bundle", "exec", mutator, *cell.argv], chdir: target_dir)
      end
      collect_report(target_dir, cell_dir)

      File.write(File.join(cell_dir, "bench.json"), JSON.pretty_generate(
        "cell" => cell.id, "target" => cell.target_name, "argv" => cell.argv,
        "baseline_seconds" => baseline_seconds.round(2),
        "mutation_seconds" => mutation_seconds.round(2),
        "exit_ok" => !!ok
      ))
    end

    def timed
      started = @clock.call
      result = yield
      [@clock.call - started, result]
    end

    def collect_report(target_dir, cell_dir)
      report = File.join(target_dir, ".active_mutator", "mutation-report.json")
      FileUtils.cp(report, File.join(cell_dir, "mutation-report.json")) if File.exist?(report)
    end

    def system_exec(argv, chdir:)
      log = File.join(@out_dir, "exec.log")
      File.open(log, "a") { |f| f.puts("$ (cd #{chdir}) #{argv.join(" ")}") }
      # BUNDLE_GEMFILE pinned to the target so `bundle exec` resolves the
      # target's bundle (which vendors active_mutator by path), not ours.
      system({ "BUNDLE_GEMFILE" => File.join(chdir, "Gemfile") },
             *argv, chdir: chdir, out: [log, "a"], err: [log, "a"])
    end
  end
end
```

- [ ] **Step 4: Run, expect PASS**

```bash
bundle exec rspec spec/bench/runner_spec.rb
```
Expected: 3 examples, 0 failures.

- [ ] **Step 5: The executables**

Create `bin/bench`:

```ruby
#!/usr/bin/env ruby
# Usage: bin/bench [--out DIR]
# Runs every cell in bench/targets.json against the committed fixture corpus
# (plus any git-pinned targets) and writes reports + timings per cell.
require "optparse"

repo_root = File.expand_path("..", __dir__)
require File.join(repo_root, "bench/lib/bench/plan")
require File.join(repo_root, "bench/lib/bench/runner")

out = File.join(repo_root, "bench/results", Time.now.strftime("%Y%m%d-%H%M%S"))
OptionParser.new do |o|
  o.banner = "Usage: bin/bench [--out DIR]"
  o.on("--out DIR", "Results directory (default: bench/results/<timestamp>)") { |v| out = File.expand_path(v) }
end.parse!

require "fileutils"
FileUtils.mkdir_p(out)
cells = Bench::Plan.load(File.join(repo_root, "bench/targets.json")).cells
Bench::Runner.new(cells: cells, repo_root: repo_root, out_dir: out).call
puts "bench results written to #{out}"
```

Create `bin/bench-diff`:

```ruby
#!/usr/bin/env ruby
# Usage: bin/bench-diff OLD_REPORT.json NEW_REPORT.json
# Diffs two Stryker mutation reports: score delta, status transitions, added/removed mutants.
require "json"

repo_root = File.expand_path("..", __dir__)
require File.join(repo_root, "bench/lib/bench/report_diff")

abort "usage: bin/bench-diff OLD.json NEW.json" unless ARGV.size == 2
a, b = ARGV.map { |p| JSON.parse(File.read(p)) }
diff = Bench::ReportDiff.new(a, b).call

puts "score: #{diff[:score_a]} -> #{diff[:score_b]} (delta #{diff[:score_delta]})"
diff[:transitions].each { |t| puts "TRANSITION #{t[:key]}: #{t[:from]} -> #{t[:to]}" }
diff[:only_in_a].each { |k| puts "REMOVED #{k}" }
diff[:only_in_b].each { |k| puts "ADDED #{k}" }
exit(diff[:transitions].empty? && diff[:only_in_a].empty? && diff[:only_in_b].empty? ? 0 : 1)
```

```bash
chmod +x bin/bench bin/bench-diff
```

Append to `.gitignore`:

```
bench/.cache/
bench/results/
```

- [ ] **Step 6: Smoke-run the harness for real**

```bash
bin/bench --out /tmp/bench-smoke
cat /tmp/bench-smoke/tiny_project-jobs1/bench.json
```
Expected: exits 0; each cell dir contains `bench.json` (with nonzero `baseline_seconds` and `mutation_seconds`) and `mutation-report.json`. Note: `exit_ok` is `false` for tiny_project cells — the fixture has planted survivors, so active_mutator exits 1 by design; that is recorded, not fatal. Then verify the differ on two cells of the same target:

```bash
bin/bench-diff /tmp/bench-smoke/tiny_project-jobs1/mutation-report.json \
               /tmp/bench-smoke/tiny_project-jobs2/mutation-report.json
```
Expected: exit 0, `score: X -> X (delta 0.0)`, no transitions (fixture statuses are deterministic across `--jobs`).

- [ ] **Step 7: Full gates**

```bash
bundle exec rspec
bundle exec exe/active_mutator lib --changed
```
Expected: both exit 0.

- [ ] **Step 8: Commit**

```bash
git add bench/lib/bench/runner.rb bin/bench bin/bench-diff spec/bench/runner_spec.rb .gitignore
git commit -m "feat(bench): bin/bench matrix runner and bin/bench-diff

Closes #21"
```

---

# Task 4 — Pin the pre-#9 bench baseline (#21 → #9 handoff)

**Files:**
- Create: `bench/baselines/tiny_project-jobs2.mutation-report.json` (copied from a real run)
- Create: `bench/baselines/README.md`
- Modify: `docs/dogfood-log.md`

- [ ] **Step 1: Produce and pin the baseline report**

```bash
bin/bench --out /tmp/bench-pre9
mkdir -p bench/baselines
cp /tmp/bench-pre9/tiny_project-jobs2/mutation-report.json \
   bench/baselines/tiny_project-jobs2.mutation-report.json
```

Create `bench/baselines/README.md`:

```markdown
# Pinned bench baselines

Committed Stryker reports from known-good runs. Compare a fresh run against
a pinned baseline with:

    bin/bench --out /tmp/bench-now
    bin/bench-diff bench/baselines/tiny_project-jobs2.mutation-report.json \
                   /tmp/bench-now/tiny_project-jobs2/mutation-report.json

Exit 0 = no status transitions, no added/removed mutants. Any scheduler,
timeout, or operator change must keep this diff clean (or update the pin
with an explanation in the commit message).

Wall times live in each run's bench.json and are environment-dependent —
they are logged in docs/dogfood-log.md, never pinned.
```

- [ ] **Step 2: Verify the pin round-trips**

```bash
bin/bench-diff bench/baselines/tiny_project-jobs2.mutation-report.json \
               /tmp/bench-pre9/tiny_project-jobs2/mutation-report.json
```
Expected: exit 0, delta 0.0, no transitions.

- [ ] **Step 3: Log timings**

Append a row to the table in `docs/dogfood-log.md` (fill measured values from `/tmp/bench-pre9/*/bench.json`):

```markdown
| 2026-07-XX | 4 pre-#9 | `bin/bench` (fixture corpus) | tiny j1/j2 + rails j2 mutation-stage seconds: <fill from bench.json> | n/a | n/a | pinned bench/baselines/tiny_project-jobs2; static timeouts |
```

- [ ] **Step 4: Full gates + commit**

```bash
bundle exec rspec
bundle exec exe/active_mutator lib --changed
git add bench/baselines docs/dogfood-log.md
git commit -m "bench: pin pre-adaptive-timeout baseline report

Refs #9 #21"
```

---

# Task 5 — `TimeoutCalibrator` (#9)

**Files:**
- Create: `lib/active_mutator/timeout_calibrator.rb`
- Modify: `lib/active_mutator.rb` (add the require, alongside the existing requires)
- Create: `spec/active_mutator/timeout_calibrator_spec.rb`
- Create: `spec/active_mutator/work_item_spec.rb`
- Modify: `lib/active_mutator/work_item.rb`

**Design.** The calibrator owns three operations:
- `record(elapsed_seconds, budget)` — called by the Scheduler when a fork finishes as a **kill** (and only then — see below). It appends the *utilization* `elapsed / budget` to a running window, where `budget` is the **effective budget the fork actually ran under** (the value `budget_for` returned at spawn time), NOT the static `item.timeout`. This kills the ratchet failure mode: if the scale is pinned at 4× and an honest kill takes 3× its static budget, its utilization against the 4×-scaled budget reads 0.75 — the median falls back toward the target and the scale recovers, instead of reading 3.0 against the static budget and pinning the scale at max forever. At equilibrium utilization self-stabilizes around `TARGET_UTILIZATION`.
- `budget_for(item)` — called at spawn. Before `WARMUP = 5` recordings it returns the static budget unchanged. After warm-up it returns `variable * scale + fixed`, where `fixed = item.timeout - item.variable` (floor + browser boot) is **not** scaled (roadmap: serial lane keeps `browser_boot_seconds` additive) and `scale = clamp(median_utilization / TARGET_UTILIZATION, 0.5, 4.0)` with `TARGET_UTILIZATION = 0.25`.
- `warmed?` / `scale` — read by the Scheduler for the once-per-change scale log line (Task 6).

**Which finishes feed the sample (decided, not optional):** *kills only*.
- `:timeout` — never recorded (the fork was SIGKILLed; its true wall time is unknowable).
- `:error` — never recorded: a crash (NameError in the mutant, boot failure) exits in a fraction of the budget; a batch of fast errors would drag the median down, shrink budgets, and *manufacture* the very false timeouts #9 exists to remove.
- `:survived` — never recorded: a survivor runs its **entire** covering set (nothing fails), while `fail_fast = 1` means a kill stops at the first failure; survivor wall times systematically overshoot kill wall times and would inflate budgets without bound.
- `:killed` — recorded: kills are the population the deadline exists to protect (issue #9's misclassified "slow-but-honest kills"), and they dominate any healthy run.

**Lane isolation (decided, not optional):** one calibrator instance **per lane**. The parallel lane finishes first and under a totally different load regime (N concurrent forks) than the serial lane (1 fork, browser + app server); pooling their samples would scale serial budgets by a parallel-derived median. The Runner builds `{ parallel: TimeoutCalibrator.new, serial: TimeoutCalibrator.new }` (Task 7) and the Scheduler routes by `item.lane` (Task 6). A serial lane that never warms up (fewer than 5 serial kills) simply keeps its static budgets — correct and conservative.

Rationale for the formula: with the static default (`factor 8`) a warm, unloaded kill uses roughly 1/8 of its budget, i.e. utilization ≈ 0.125–0.25. If the median observed utilization creeps toward 1.0 (parallel load), honest kills are about to be misclassified as timeouts, so remaining budgets grow by up to 4×. If utilization is tiny, budgets shrink (never below half, and never below the unscaled fixed part), reclaiming wall time from dead workers. `WorkItem` gains two fields in this task: `variable` (the `estimate * factor` part) and `boot_extra` (0.0 parallel / `browser_boot_seconds` serial), both defaulted to `0.0` and pinned by spec here; `timeout` stays the static total so `--debug-plan` output and every existing caller are unchanged.

- [ ] **Step 1: Write the failing spec**

Create `spec/active_mutator/timeout_calibrator_spec.rb`:

```ruby
RSpec.describe ActiveMutator::TimeoutCalibrator do
  def item(timeout: 20.0, variable: 8.0, boot_extra: 0.0)
    ActiveMutator::WorkItem.new(mutation: nil, example_ids: [], timeout: timeout,
                                lane: :parallel, variable: variable, boot_extra: boot_extra)
  end

  it "returns the static budget before warm-up completes, and reports warmed? accordingly" do
    cal = described_class.new
    4.times { cal.record(19.0, 20.0) } # 4 < WARMUP
    expect(cal.warmed?).to be false
    expect(cal.budget_for(item)).to eq(20.0)
    cal.record(19.0, 20.0)
    expect(cal.warmed?).to be true
  end

  it "grows remaining budgets when observed utilization exceeds the target" do
    cal = described_class.new
    5.times { cal.record(15.0, 20.0) } # utilization 0.75, scale 3.0
    # variable 8.0 * 3.0 + fixed (20.0 - 8.0) = 36.0
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(36.0)
  end

  it "shrinks budgets when utilization is far below the target, clamped at 0.5x" do
    cal = described_class.new
    5.times { cal.record(0.2, 20.0) } # utilization 0.01 -> clamp 0.5
    # variable 8.0 * 0.5 + fixed 12.0 = 16.0
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(16.0)
  end

  it "clamps growth at 4x" do
    cal = described_class.new
    5.times { cal.record(20.0, 20.0) } # utilization 1.0 -> 4.0 capped
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(44.0)
  end

  it "recovers from a pinned-high scale because utilization is measured against the effective budget" do
    cal = described_class.new
    5.times { cal.record(20.0, 20.0) }   # load spike: utilization 1.0 -> scale 4.0
    expect(cal.scale).to eq(4.0)
    # Subsequent forks ran under 4x-scaled budgets (80.0); the same honest
    # 20s kills now record utilization 0.25 against the budget they ACTUALLY
    # had. Median: sorted [0.25 x6, 1.0 x5] -> 0.25 -> scale back to 1.0.
    6.times { cal.record(20.0, 80.0) }
    expect(cal.scale).to eq(1.0)
  end

  it "uses the median, so one outlier does not swing the scale" do
    cal = described_class.new
    4.times { cal.record(5.0, 20.0) } # utilization 0.25 -> scale 1.0
    cal.record(20.0, 20.0)            # single outlier
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(20.0)
  end

  it "never scales the fixed part (floor + browser boot stay additive)" do
    cal = described_class.new
    5.times { cal.record(15.0, 20.0) } # scale 3.0
    serial = item(timeout: 35.0, variable: 8.0, boot_extra: 15.0)
    # 8.0 * 3.0 + (35.0 - 8.0) = 51.0 : the 15s browser boot and 12s floor untouched
    expect(cal.budget_for(serial)).to eq(51.0)
  end

  it "ignores recordings with a non-positive budget" do
    cal = described_class.new
    5.times { cal.record(5.0, 0.0) }
    expect(cal.warmed?).to be false
    expect(cal.budget_for(item(timeout: 20.0))).to eq(20.0)
  end
end
```

And pin the new `WorkItem` defaults (they are load-bearing for every pre-existing construction site until Task 6 populates them — without this spec, default-value mutants would survive this task's gate). Add to a new `spec/active_mutator/work_item_spec.rb`:

```ruby
RSpec.describe ActiveMutator::WorkItem do
  it "defaults variable and boot_extra to 0.0 so existing call sites are unchanged" do
    item = described_class.new(mutation: nil, example_ids: [], timeout: 5.0, lane: :parallel)
    expect(item.variable).to eq(0.0)
    expect(item.boot_extra).to eq(0.0)
  end

  it "accepts explicit variable and boot_extra" do
    item = described_class.new(mutation: nil, example_ids: [], timeout: 5.0, lane: :serial,
                               variable: 2.0, boot_extra: 15.0)
    expect(item.variable).to eq(2.0)
    expect(item.boot_extra).to eq(15.0)
  end
end
```

- [ ] **Step 2: Run, expect FAIL**

```bash
bundle exec rspec spec/active_mutator/timeout_calibrator_spec.rb spec/active_mutator/work_item_spec.rb
```
Expected: NameError (uninitialized constant `TimeoutCalibrator`) and ArgumentError on the `WorkItem` kwargs (`variable`/`boot_extra` don't exist yet); both arrive in Step 3.

- [ ] **Step 3: Implement**

First widen `lib/active_mutator/work_item.rb` (defaults keep every existing constructor call valid):

```ruby
module ActiveMutator
  # lane: :parallel (default pool) | :serial (browser-covered, one at a time)
  # timeout:    static total budget (variable + fixed), kept for --debug-plan and compat
  # variable:   the baseline-estimate-derived part (estimate * timeout_factor) — the
  #             only part the TimeoutCalibrator scales
  # boot_extra: browser_boot_seconds for the serial lane, 0.0 otherwise (always additive)
  WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane, :variable, :boot_extra) do
    def initialize(mutation:, example_ids:, timeout:, lane:, variable: 0.0, boot_extra: 0.0)
      super
    end
  end
end
```

Create `lib/active_mutator/timeout_calibrator.rb`:

```ruby
module ActiveMutator
  # Adaptive timeout budgets (#9). Static budgets derive from baseline times
  # measured warm and unloaded; under parallel load they misclassify
  # slow-but-honest kills as timeouts. The Scheduler feeds this with the
  # observed wall time of every KILLED fork (errors exit artificially fast,
  # survivors run their whole covering set — both would bias the median;
  # timed-out forks have no known wall time at all). One instance per lane:
  # parallel and serial run under different load regimes.
  #
  # Utilization is elapsed / the EFFECTIVE budget the fork ran under (the
  # value budget_for returned at its spawn), not the static item.timeout —
  # otherwise a pinned-high scale could never observe recovery (ratchet).
  # Once WARMUP observations exist, remaining budgets' variable part is
  # scaled by the clamped median utilization. The fixed part (timeout_floor
  # + browser boot) is never scaled: fork boot cost does not shrink because
  # examples run fast.
  class TimeoutCalibrator
    WARMUP = 5
    TARGET_UTILIZATION = 0.25
    MIN_SCALE = 0.5
    MAX_SCALE = 4.0

    def initialize
      @utilizations = []
    end

    def record(elapsed_seconds, budget)
      return unless budget.positive?

      @utilizations << elapsed_seconds / budget
    end

    def warmed? = @utilizations.size >= WARMUP

    def budget_for(item)
      return item.timeout unless warmed?

      fixed = item.timeout - item.variable
      item.variable * scale + fixed
    end

    def scale
      s = median(@utilizations) / TARGET_UTILIZATION
      s.clamp(MIN_SCALE, MAX_SCALE)
    end

    private

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
```

Add to `lib/active_mutator.rb`, next to the existing `require_relative` lines (match the file's style — check whether it uses `require` or `require_relative` and mirror it):

```ruby
require "active_mutator/timeout_calibrator"
```

- [ ] **Step 4: Run, expect PASS**

```bash
bundle exec rspec spec/active_mutator/timeout_calibrator_spec.rb spec/active_mutator/work_item_spec.rb
bundle exec rspec
```
Expected: all green — the WorkItem defaults keep every existing `WorkItem.new(...)` call site compiling, and `work_item_spec.rb` pins those defaults so default-value mutants (`0.0`→`1.0`) die in this task's gate, not Task 6's.

- [ ] **Step 5: Self-mutation gate**

```bash
bundle exec exe/active_mutator lib --changed
```
Expected: exit 0. Prime survivor candidates: `clamp` bound mutants (`0.5`→`0.51`), `WARMUP` off-by-one (`<`→`<=`), median even/odd branch. The specs above kill each (warm-up boundary spec, both clamp specs, the 5-element median spec plus an even-count path exercised by the 4-recording warm-up spec once implementation runs `median` — if a median mutant survives, add a 6-recording even-window spec rather than accepting).

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/timeout_calibrator.rb lib/active_mutator/work_item.rb \
        lib/active_mutator.rb spec/active_mutator/timeout_calibrator_spec.rb \
        spec/active_mutator/work_item_spec.rb
git commit -m "feat: TimeoutCalibrator — median-utilization budget scaling

Refs #9"
```

---

# Task 6 — Runner populates `variable`/`boot_extra`; Scheduler consults the calibrator (#9)

**Files:**
- Modify: `lib/active_mutator/runner.rb` (`plan_work`, `call`)
- Modify: `lib/active_mutator/scheduler.rb` (`initialize`, `spawn`, `reap`)
- Modify: `spec/active_mutator/runner_spec.rb`, `spec/active_mutator/scheduler_spec.rb`

- [ ] **Step 1: Failing Runner spec**

Add to `spec/active_mutator/runner_spec.rb`, inside the existing `plan_work` describe block (reuse that block's existing `config`/`map`/mutation helpers — the block already builds work items and asserts on `timeout`):

```ruby
it "records the variable and fixed budget parts on the work item" do
  # Use the block's existing helpers to plan one parallel item whose
  # baseline estimate is nonzero, then:
  item = items.first
  expect(item.variable).to eq(map.time_for(item.example_ids) * config.timeout_factor)
  expect(item.boot_extra).to eq(0.0)
  expect(item.timeout).to eq(item.variable + config.timeout_floor)
end

it "marks the serial lane's browser boot as boot_extra" do
  # Plan one serial-lane item via the block's existing serial fixture, then:
  expect(serial_item.boot_extra).to eq(config.browser_boot_seconds)
  expect(serial_item.timeout)
    .to eq(serial_item.variable + config.timeout_floor + config.browser_boot_seconds)
end
```

Run: `bundle exec rspec spec/active_mutator/runner_spec.rb` → FAIL (`variable` is 0.0).

- [ ] **Step 2: Implement in `Runner#plan_work`**

Replace the timeout computation (`runner.rb:54-56`) with:

```ruby
          lane = example_ids.any? { |id| serial_example?(id) } ? :serial : :parallel
          variable = map.time_for(example_ids) * @config.timeout_factor
          boot_extra = lane == :serial ? @config.browser_boot_seconds : 0.0
          timeout = variable + @config.timeout_floor + boot_extra
          items << WorkItem.new(mutation: mutation, example_ids: example_ids,
                                timeout: timeout, lane: lane,
                                variable: variable, boot_extra: boot_extra)
```

Run the runner spec → PASS. (The arithmetic is identical to the old formula; `--debug-plan` output is byte-for-byte unchanged.)

- [ ] **Step 3: Failing Scheduler specs**

Add to `spec/active_mutator/scheduler_spec.rb` (reuse the file's `item`/`scheduler` helpers; extend the `scheduler` helper to pass `calibrators:` through). Add a stub-builder at the top of the new describe block:

```ruby
describe "adaptive timeouts" do
  def fake_calibrator(budget: nil, scale: 1.0, warmed: false)
    cal = instance_double(ActiveMutator::TimeoutCalibrator,
                          scale: scale, warmed?: warmed)
    if budget
      allow(cal).to receive(:budget_for).and_return(budget)
    else
      allow(cal).to receive(:budget_for) { |i| i.timeout }
    end
    allow(cal).to receive(:record)
    cal
  end

  def killed_worker
    ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
  end

  it "asks the lane's calibrator for the effective budget at spawn time" do
    # Static timeout is generous, but the calibrator returns a tiny budget:
    # the sleeping worker must be reaped as a timeout.
    cal = fake_calibrator(budget: 0.2)
    worker = ->(_m, _e, _w) { sleep 30 }
    results = scheduler(worker: worker, calibrators: { parallel: cal, serial: cal })
              .run([item(timeout: 60.0)])
    expect(results.map(&:status)).to eq([:timeout])
  end

  it "records killed forks with their elapsed time AND the effective budget they ran under" do
    recordings = []
    cal = fake_calibrator(budget: 5.0)
    allow(cal).to receive(:record) { |elapsed, budget| recordings << [elapsed, budget] }
    scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal })
      .run([item(timeout: 60.0), item(timeout: 60.0)])
    expect(recordings.size).to eq(2)
    # The denominator is the scaled budget (5.0), never the static 60.0 —
    # recording against the static budget would ratchet the scale to max.
    expect(recordings).to all(satisfy { |(elapsed, budget)| elapsed.positive? && budget == 5.0 })
  end

  it "routes recordings to the calibrator of the item's lane" do
    parallel_cal = fake_calibrator
    serial_cal = fake_calibrator
    scheduler(worker: killed_worker, calibrators: { parallel: parallel_cal, serial: serial_cal })
      .run([item(lane: :parallel), item(lane: :serial)])
    expect(parallel_cal).to have_received(:record).once
    expect(serial_cal).to have_received(:record).once
  end

  it "does not record survived or errored forks (they would bias the median)" do
    cal = fake_calibrator
    survived = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "survived", "details" => nil)) }
    errored  = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "error", "details" => "boom")) }
    scheduler(worker: survived, calibrators: { parallel: cal, serial: cal }).run([item])
    scheduler(worker: errored, calibrators: { parallel: cal, serial: cal }).run([item])
    expect(cal).not_to have_received(:record)
  end

  it "does not record timed-out forks (their true wall time is unknown)" do
    cal = fake_calibrator(budget: 0.2)
    worker = ->(_m, _e, _w) { sleep 30 }
    scheduler(worker: worker, calibrators: { parallel: cal, serial: cal }).run([item(timeout: 60.0)])
    expect(cal).not_to have_received(:record)
  end

  it "runs on static budgets when no calibrators are given" do
    worker = ->(_m, _e, _w) { sleep 30 }
    results = scheduler(worker: worker).run([item(timeout: 0.2)])
    expect(results.map(&:status)).to eq([:timeout])
  end

  it "logs the scale to stderr once per change, not once per spawn" do
    cal = fake_calibrator(warmed: true, scale: 2.4)
    expect do
      scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal })
        .run([item, item, item])
    end.to output(/active_mutator: adaptive timeout scale 2\.4\n/).to_stderr_from_any_process
    # exactly once: the regex above plus a negative count check
    # (capture stderr into a StringIO if the file has a helper for it; otherwise:)
    expect do
      scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal })
        .run([item, item])
    end.to output(satisfy { |s| s.scan("adaptive timeout scale").size == 1 }).to_stderr_from_any_process
  end

  it "does not log the scale before warm-up" do
    cal = fake_calibrator(warmed: false)
    expect do
      scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal }).run([item])
    end.not_to output(/adaptive timeout scale/).to_stderr_from_any_process
  end
end
```

Update the file's helper:

```ruby
  def scheduler(worker:, jobs: 2, on_result: nil, calibrators: nil)
    described_class.new(jobs: jobs, worker: worker, on_result: on_result, calibrators: calibrators)
  end
```

Run: `bundle exec rspec spec/active_mutator/scheduler_spec.rb` → FAIL (unknown keyword `calibrators`).

- [ ] **Step 4: Implement in Scheduler**

`initialize` gains the collaborator — a `{parallel:, serial:}` hash of per-lane calibrators (lane isolation, see Task 5 design):

```ruby
    def initialize(jobs:, worker: Worker.method(:run), on_result: nil,
                   calibrators: nil, orphaned: -> { Process.ppid == 1 })
      @jobs = jobs
      @worker = worker
      @on_result = on_result
      @calibrators = calibrators
      @orphaned = orphaned
      @last_logged_scale = nil
    end
```

`#spawn` — budget via the lane's calibrator; remember start time AND the effective budget (the record denominator):

```ruby
      writer.close
      calibrator = calibrator_for(item)
      budget = calibrator ? calibrator.budget_for(item) : item.timeout
      log_scale(calibrator)
      started = now
      running[pid] = { reader: reader, item: item, started: started,
                       budget: budget, deadline: started + budget }
```

`#reap` — feed the calibrator only when the fork reports a **kill** (see Task 5 design: errors finish artificially fast, survivors run the whole covering set, timeouts have no known wall time). `finish` must therefore run before the recording decision:

```ruby
        if done
          running.delete(pid)
          result = finish(entry)
          if result.status == :killed
            calibrator_for(entry[:item])&.record(now - entry[:started], entry[:budget])
          end
          results << result
```

New private methods:

```ruby
    def calibrator_for(item)
      @calibrators && @calibrators[item.lane]
    end

    # Effective budgets are otherwise invisible (--debug-plan shows static
    # ones by design). One stderr line per scale CHANGE, not per spawn.
    def log_scale(calibrator)
      return unless calibrator&.warmed?

      scale = calibrator.scale.round(2)
      return if scale == @last_logged_scale

      @last_logged_scale = scale
      warn "active_mutator: adaptive timeout scale #{scale}"
    end
```

Run the scheduler spec → PASS.

- [ ] **Step 5: Full gates + commit**

```bash
bundle exec rspec
bundle exec exe/active_mutator lib --changed
git add lib/active_mutator/runner.rb lib/active_mutator/scheduler.rb \
        spec/active_mutator/runner_spec.rb spec/active_mutator/scheduler_spec.rb
git commit -m "feat: scheduler consults TimeoutCalibrator for fork deadlines

Refs #9"
```

---

# Task 7 — Wire-up, `--no-adaptive-timeout` opt-out, config-file key, docs (#9)

**Files:**
- Modify: `lib/active_mutator/config.rb`, `lib/active_mutator/cli.rb`, `lib/active_mutator/config_file.rb`, `lib/active_mutator/runner.rb` (`#call`)
- Modify: `spec/active_mutator/cli_spec.rb`, `spec/active_mutator/config_file_spec.rb`, `spec/active_mutator/runner_spec.rb`
- Modify: `README.md`

Backward compatibility: adaptive is the new default (it strictly reduces the false-timeout failure mode the static flags were band-aiding), `--timeout-factor`/`--timeout-floor` keep their exact meaning as the *inputs* to the static budget the calibrator starts from and falls back to, and `--no-adaptive-timeout` restores pre-#9 behavior bit-for-bit.

- [ ] **Step 1: Failing CLI + config-file specs**

`spec/active_mutator/cli_spec.rb` (match the file's existing one-liner style):

```ruby
it "defaults adaptive_timeout to true" do
  expect(described_class.parse([]).adaptive_timeout).to be true
end

it "parses --no-adaptive-timeout" do
  expect(described_class.parse(["--no-adaptive-timeout"]).adaptive_timeout).to be false
end
```

`spec/active_mutator/config_file_spec.rb` (match the file's existing tmpdir + YAML-writing style):

```ruby
it "accepts adaptive_timeout: false" do
  write_config("adaptive_timeout" => false)
  expect(described_class.load(root)[:adaptive_timeout]).to be false
end

it "rejects a non-boolean adaptive_timeout" do
  write_config("adaptive_timeout" => "nope")
  expect { described_class.load(root) }
    .to raise_error(ActiveMutator::Error, /adaptive_timeout must be true or false/)
end
```

Run both spec files → FAIL.

- [ ] **Step 2: Implement — including every `Config.new` call site**

`config.rb` — append `:adaptive_timeout` to the `Data.define` list.

**`Data.define` has no defaults: every existing `Config.new(...)` with an explicit keyword list now raises `ArgumentError: missing keyword: :adaptive_timeout` until updated.** Audit first, and re-verify (the list below is current as of this plan):

```bash
grep -rn "Config.new" lib spec
```

Exactly two call sites exist:
1. `lib/active_mutator/cli.rb:59` — `Config.new(paths: paths, root: Dir.pwd, **options)`: **no edit needed**; the defaults hash gains `adaptive_timeout: true` above, so `**options` always carries the key.
2. `spec/active_mutator/runner_spec.rb:5-13` — the base `let(:config)`: **must be edited**. Exact change:

```ruby
  let(:config) do
    ActiveMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: "/project", preload_helper: nil, serial_patterns: ["spec/system/", "spec/features/"],
      browser_boot_seconds: 15.0, accept_survivors: false, exclude: [],
      max_mutants: nil, debug_plan: false, fail_at: nil, adaptive_timeout: true
    )
  end
```

If your grep finds any call site not listed here (added by an earlier phase task), give it `adaptive_timeout: true` the same way. Run `bundle exec rspec spec/active_mutator/runner_spec.rb` immediately after this edit — every example in the file must compile again before you continue.

`cli.rb` — defaults hash gains `adaptive_timeout: true`; add the option next to the timeout flags:

```ruby
        o.on("--[no-]adaptive-timeout", "Scale timeout budgets from observed worker wall times (default: on)") { |v| options[:adaptive_timeout] = v }
```

`config_file.rb` — `KEYS` gains `"adaptive_timeout" => :boolean`; `coerce` gains:

```ruby
      when :boolean
        unless [true, false].include?(value)
          raise Error, "#{FILENAME}: #{key} must be true or false"
        end
        value
```

Run both spec files → PASS.

- [ ] **Step 3: Failing Runner wiring spec**

In `spec/active_mutator/runner_spec.rb`, near the existing `Runner#call` collaborator-stubbing specs (reuse their config/stub scaffolding):

```ruby
it "passes per-lane TimeoutCalibrators to the scheduler when adaptive_timeout is on" do
  # config with adaptive_timeout: true (the default); stub Scheduler
  expect(ActiveMutator::Scheduler).to receive(:new)
    .with(hash_including(calibrators: {
      parallel: kind_of(ActiveMutator::TimeoutCalibrator),
      serial: kind_of(ActiveMutator::TimeoutCalibrator)
    }))
    .and_return(instance_double(ActiveMutator::Scheduler, run: []))
  runner.call
end

it "builds distinct calibrator instances per lane (no cross-lane sample pooling)" do
  captured = nil
  expect(ActiveMutator::Scheduler).to receive(:new) do |**kwargs|
    captured = kwargs[:calibrators]
    instance_double(ActiveMutator::Scheduler, run: [])
  end
  runner.call
  expect(captured[:parallel]).not_to be(captured[:serial])
end

it "passes no calibrators when adaptive_timeout is off" do
  # config with adaptive_timeout: false
  expect(ActiveMutator::Scheduler).to receive(:new)
    .with(hash_including(calibrators: nil))
    .and_return(instance_double(ActiveMutator::Scheduler, run: []))
  runner.call
end
```

Run → FAIL. Implement in `Runner#call` (line ~31):

```ruby
      calibrators = if @config.adaptive_timeout
                      { parallel: TimeoutCalibrator.new, serial: TimeoutCalibrator.new }
                    end
      scheduler = Scheduler.new(jobs: @config.jobs, on_result: @reporter.method(:on_result),
                                calibrators: calibrators)
```

Run → PASS.

- [ ] **Step 4: Bench stays deterministic — cells opt out of adaptive timeouts**

The bench-diff exit-0 gate (Task 4's pinned baseline) is a regression detector; adaptive budgets are load-dependent and could flip Killed↔Timeout between runs, turning the gate intermittently red. Bench cells therefore always run `--no-adaptive-timeout`; adaptive behavior is benchmarked only when a target's matrix explicitly asks for it.

Failing spec — update `spec/bench/plan_spec.rb`: change the two `argv` expectations to

```ruby
      expect(cells.first.argv).to eq(
        ["lib", "--jobs", "1", "--timeout-factor", "8.0",
         "--no-adaptive-timeout", "--format", "stryker-json"]
      )
```
and
```ruby
      expect(cells.first.argv).to eq(["lib", "--no-adaptive-timeout", "--format", "stryker-json"])
```
and add:
```ruby
  it "lets a matrix row opt back in to adaptive timeouts as a boolean flag" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "tiny", "type" => "path", "path" => "spec/fixtures/tiny_project",
          "paths" => ["lib"], "matrix" => { "adaptive_timeout" => [true, false] } }
      ])
      argvs = described_class.load(path).cells.map(&:argv)
      expect(argvs[0]).to eq(["lib", "--adaptive-timeout", "--format", "stryker-json"])
      expect(argvs[1]).to eq(["lib", "--no-adaptive-timeout", "--format", "stryker-json"])
    end
  end
```

Run → FAIL. Implement in `bench/lib/bench/plan.rb`: `expand`'s argv line becomes

```ruby
          argv: target.fetch("paths", []) + flag_argv(combo) +
                adaptive_default(combo) + ["--format", "stryker-json"]
```

with two new private methods (booleans render as `--flag`/`--no-flag`, and the default opt-out is skipped when the matrix pins the flag itself):

```ruby
    # Deterministic by default: adaptive budgets are load-dependent and would
    # make the bench-diff regression gate flaky. Matrix rows may override.
    def adaptive_default(combo)
      combo.key?("adaptive_timeout") ? [] : ["--no-adaptive-timeout"]
    end

    def flag_argv(combo)
      combo.flat_map do |flag, v|
        name = flag.tr("_", "-")
        case v
        when true  then ["--#{name}"]
        when false then ["--no-#{name}"]
        else ["--#{name}", v.to_s]
        end
      end
    end
```

(This replaces Task 2's simpler `flag_argv`; the cell ids from `cell_id` are unaffected for non-boolean flags — boolean matrix values produce ids like `tiny-adaptivetimeouttrue` via the `abbrev` fallback, which is fine.) Run `bundle exec rspec spec/bench` → PASS. Re-pin is NOT needed: the pinned baseline was produced pre-adaptive, and cells now run with adaptive off — statuses are unchanged by construction.

- [ ] **Step 5: README + guide**

`README.md` flag table: add

```markdown
| `--[no-]adaptive-timeout` | on | scale timeout budgets from observed worker wall times (median utilization, clamped 0.5x–4x; `--timeout-factor`/`--timeout-floor` set the starting budget) |
```

and add `adaptive_timeout` to the `.active_mutator.yml` key list. In `docs/guides/how-it-works.md`, in the scheduler/timeout section, add one paragraph describing the calibrator: warm-up of 5 **killed** forks per lane (errors/survivors/timeouts never sampled), median utilization measured against the effective budget each fork ran under, target 0.25, clamp 0.5–4, fixed part (floor + browser boot) never scaled, one calibrator per lane, and the `active_mutator: adaptive timeout scale N.NN` stderr line emitted whenever the applied scale changes (that log line is how users see effective budgets; `--debug-plan` intentionally keeps showing the static ones).

- [ ] **Step 6: e2e sanity + bench regression check**

```bash
ACTIVE_MUTATOR_E2E=1 bundle exec rspec spec/e2e
bin/bench --out /tmp/bench-post9
bin/bench-diff bench/baselines/tiny_project-jobs2.mutation-report.json \
               /tmp/bench-post9/tiny_project-jobs2/mutation-report.json
```
Expected: e2e green; bench-diff exit 0. The bench cells run `--no-adaptive-timeout` (Step 4), so this check proves the *plumbing* changed nothing when adaptive is off — the deterministic gate stays deterministic. To eyeball adaptive behavior itself, run one fixture manually: `cd spec/fixtures/tiny_project && BUNDLE_GEMFILE=$PWD/Gemfile bundle exec ../../../exe/active_mutator lib --jobs 2` and confirm statuses match the pinned baseline and any `adaptive timeout scale` stderr lines look sane. Log the post-#9 `mutation_seconds` next to the Task 4 row in `docs/dogfood-log.md`.

- [ ] **Step 7: Full gates + commit**

```bash
bundle exec rspec
bundle exec exe/active_mutator lib --changed
git add lib/active_mutator/config.rb lib/active_mutator/cli.rb lib/active_mutator/config_file.rb \
        lib/active_mutator/runner.rb bench/lib/bench/plan.rb spec/bench/plan_spec.rb \
        spec/active_mutator/cli_spec.rb \
        spec/active_mutator/config_file_spec.rb spec/active_mutator/runner_spec.rb \
        README.md docs/guides/how-it-works.md docs/dogfood-log.md
git commit -m "feat: adaptive timeout calibration on by default, --no-adaptive-timeout opt-out

Closes #9"
```

---

# Task 8 — `DefinedConstants`: what does a changed source file define? (#11)

**Files:**
- Create: `lib/active_mutator/defined_constants.rb`
- Modify: `lib/active_mutator.rb` (require)
- Create: `spec/active_mutator/defined_constants_spec.rb`

**Design — qualified names only, deliberately.** An earlier draft also emitted bare leaf names (`"Config"` for `ActiveMutator::Config`). That is a trap: common leaves (`Config`, `Base`, `Client`, `Error`) appear in half of any real suite's spec files, which would trip Task 9's >50% full-run fallback on nearly every edit to such files — silently defeating incremental mode. Rule: emit every *fully qualified* scope path (`"Billing"`, `"Billing::Invoice"`) and nothing else. A top-level `class Invoice` naturally yields `"Invoice"` (its qualified name IS the leaf), so the common `RSpec.describe Invoice` case still matches. Recall tradeoff accepted and documented in Task 10: a spec referencing a nested constant by bare leaf only (inside its own matching namespace nesting) is missed — that residual falls to nightly `--force-baseline`.

**Parse-failure boundary, pinned:** the guard is `result.errors.any?` — parse **errors** (truncated input, `class Oops`) blank the result to `[]`; parse **warnings** (e.g. `if a = 2` assignment-in-condition) do not, because Prism still produces a complete AST for them. Residual case: Prism's error *recovery* can produce a partial AST for badly broken input in which some definitions are still visible — we return whatever definitions survive recovery only when `errors` is empty, i.e. never for broken input; a file that is mid-edit and unparseable simply contributes no reference candidates until it parses again (and `--force-baseline` remains the backstop).

- [ ] **Step 1: Failing spec**

Create `spec/active_mutator/defined_constants_spec.rb`:

```ruby
require "prism"

RSpec.describe ActiveMutator::DefinedConstants do
  it "collects nested class and module names, fully qualified only" do
    names = described_class.in_source(<<~RUBY)
      module Billing
        class Invoice
          def total; end
        end
      end
    RUBY
    expect(names).to contain_exactly("Billing", "Billing::Invoice")
  end

  it "keeps a top-level class name as-is" do
    expect(described_class.in_source("class Invoice; end\n")).to eq(["Invoice"])
  end

  it "handles compact constant paths" do
    names = described_class.in_source("class Billing::Invoice; end\n")
    expect(names).to contain_exactly("Billing::Invoice")
  end

  it "never emits a bare common leaf for a nested definition (the Config problem)" do
    names = described_class.in_source(<<~RUBY)
      module MyApp
        class Config
        end
      end
    RUBY
    expect(names).to contain_exactly("MyApp", "MyApp::Config")
    expect(names).not_to include("Config")
  end

  it "returns [] when the parse has errors (truncated / mid-edit input)" do
    src = "class Oops"
    expect(Prism.parse(src).errors).not_to be_empty # pin the fixture's nature
    expect(described_class.in_source(src)).to eq([])
  end

  it "still returns names when the parse only has warnings" do
    src = <<~RUBY
      class Invoice
        def f(a)
          1 if a = 2
        end
      end
    RUBY
    result = Prism.parse(src)
    expect(result.errors).to be_empty          # pin the boundary:
    expect(result.warnings).not_to be_empty    # warnings-only input must not blank the result
    expect(described_class.in_source(src)).to eq(["Invoice"])
  end

  it "returns [] for source defining no constants" do
    expect(described_class.in_source("puts 1\n")).to eq([])
  end
end
```

(If the `a = 2` fixture stops producing a Prism warning on a future Prism version, the two `expect(result...)` precondition lines fail loudly — swap in another warnings-only construct rather than deleting the boundary spec.)

Run: `bundle exec rspec spec/active_mutator/defined_constants_spec.rb` → NameError.

- [ ] **Step 2: Implement**

Create `lib/active_mutator/defined_constants.rb`:

```ruby
require "prism"

module ActiveMutator
  # Fully qualified names of classes/modules a source file defines
  # ("Billing", "Billing::Invoice"). Deliberately NO bare leaf shorthand for
  # nested definitions: common leaves like "Config"/"Base" textually match
  # half of any real spec suite and would trip BaselineDelta's full-run
  # fallback on every edit, silently defeating incremental mode. Top-level
  # definitions keep their (leaf == qualified) name, so `RSpec.describe Foo`
  # still matches for the common flat-namespace case.
  #
  # Guard is errors.any?, not warnings: Prism produces a complete AST for
  # warnings-only input (`if a = 2`), and those definitions are real.
  module DefinedConstants
    def self.in_source(source)
      result = Prism.parse(source)
      return [] if result.errors.any?

      names = []
      walk(result.value, [], names)
      names.uniq
    end

    def self.walk(node, scope, names)
      if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        scope = scope + [node.constant_path.slice]
        names << scope.join("::")
      end
      node.compact_child_nodes.each { |child| walk(child, scope, names) }
    end
    private_class_method :walk
  end
end
```

Add the require to `lib/active_mutator.rb` next to the others.

- [ ] **Step 3: Run, expect PASS; gates; commit**

```bash
bundle exec rspec spec/active_mutator/defined_constants_spec.rb
bundle exec rspec
bundle exec exe/active_mutator lib --changed
git add lib/active_mutator/defined_constants.rb lib/active_mutator.rb \
        spec/active_mutator/defined_constants_spec.rb
git commit -m "feat: DefinedConstants — Prism walk of class/module names

Refs #11"
```

---

# Task 9 — `BaselineDelta` re-runs constant-referencing, non-covering spec files (#11)

**Files:**
- Modify: `lib/active_mutator/baseline_delta.rb`
- Modify: `spec/active_mutator/baseline_delta_spec.rb`

**Design.** For every changed (or added) source file that exists on disk: extract its defined constants (Task 8's **qualified-only** names — this is what keeps common leaves like `Config` from matching everything); find spec files under `spec/**/*_spec.rb` whose text matches any of those names (word-boundary regex); keep only spec files that currently contribute **zero** coverage to the changed file (spec files with covering examples are already handled by `rerun_example_ids`, and re-running them wholesale would regress incremental speed); add the survivors to `rerun_spec_files` (merge_partial! already drops-and-replaces their records by prefix). Safety valve: if the candidates exceed `REFERENCE_FULL_RATIO = 0.5` of all spec files, a full re-run is cheaper — return FULL **and warn on stderr** (a silent fallback would look like incremental mode hanging). Everything is disk-guarded, so the existing pure-hash specs (root `"/project"`, no real files) are untouched.

- [ ] **Step 1: Failing specs**

Add to `spec/active_mutator/baseline_delta_spec.rb`:

```ruby
  describe "newly-covering candidates (#11)" do
    require "fileutils"
    require "tmpdir"

    def project(files)
      Dir.mktmpdir do |dir|
        files.each do |rel, content|
          abs = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(abs))
          File.write(abs, content)
        end
        yield dir
      end
    end

    it "re-runs an unchanged spec file that references the changed constant but covers none of it" do
      project(
        "lib/invoice.rb" => "class Invoice; def total; 1; end; end\n",
        "spec/invoice_shared_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/other_spec.rb" => "RSpec.describe Object do; end\n"
      ) do |root|
        recs = { "./spec/other_spec.rb[1:1]" => [[File.join(root, "lib/other.rb"), 1]] }
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map(recs), root: root
        )
        expect(delta.full?).to be(false)
        expect(delta.rerun_spec_files).to eq(["spec/invoice_shared_spec.rb"])
      end
    end

    it "does not re-run a referencing spec file that already covers the changed file" do
      project(
        "lib/invoice.rb" => "class Invoice; def total; 1; end; end\n",
        "spec/invoice_spec.rb" => "RSpec.describe Invoice do; end\n"
      ) do |root|
        recs = { "./spec/invoice_spec.rb[1:1]" => [[File.join(root, "lib/invoice.rb"), 1]] }
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map(recs), root: root
        )
        expect(delta.rerun_spec_files).to eq([])
        expect(delta.rerun_example_ids).to eq(["./spec/invoice_spec.rb[1:1]"])
      end
    end

    it "scans newly added source files too" do
      project(
        "lib/invoice.rb" => "class Invoice; end\n",
        "spec/invoice_shared_spec.rb" => "RSpec.describe Invoice do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: {}, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.rerun_spec_files).to eq(["spec/invoice_shared_spec.rb"])
      end
    end

    it "falls back to a full run when the referencing set exceeds half of all spec files" do
      project(
        "lib/invoice.rb" => "class Invoice; end\n",
        "spec/a_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/b_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/c_spec.rb" => "RSpec.describe Object do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.full?).to be(true)
      end
    end

    it "ignores deleted source files (nothing on disk to scan)" do
      project("spec/a_spec.rb" => "RSpec.describe Invoice do; end\n") do |root|
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: {},
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.rerun_spec_files).to eq([])
      end
    end

    it "warns when the reference scan trips the full-run fallback (never silent)" do
      project(
        "lib/invoice.rb" => "class Invoice; end\n",
        "spec/a_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/b_spec.rb" => "RSpec.describe Invoice do; end\n"
      ) do |root|
        expect do
          described_class.compute(
            old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
            coverage_map: coverage_map({}), root: root
          )
        end.to output(/constant-reference scan matched 2 of 2 spec files.*falling back to full baseline/)
          .to_stderr
      end
    end

    it "does not blow up incremental mode for files defining common nested leaf names" do
      # MyApp::Config is nested: DefinedConstants (Task 8) must not emit bare
      # "Config", so the many spec files mentioning "Config" unqualified do
      # NOT become candidates and the full-run fallback does not trip.
      project(
        "lib/my_app/config.rb" => "module MyApp; class Config; end; end\n",
        "spec/a_spec.rb" => "RSpec.describe \"a\" do; end # Config mentioned bare\n",
        "spec/b_spec.rb" => "RSpec.describe \"b\" do; end # Config mentioned bare\n",
        "spec/c_spec.rb" => "RSpec.describe MyApp::Config do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/my_app/config.rb" => "x" },
          new_digests: { "lib/my_app/config.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.full?).to be(false)
        expect(delta.rerun_spec_files).to eq(["spec/c_spec.rb"])
      end
    end
  end
```

Run: `bundle exec rspec spec/active_mutator/baseline_delta_spec.rb` → new examples FAIL (`rerun_spec_files` empty / not FULL).

- [ ] **Step 2: Implement**

In `lib/active_mutator/baseline_delta.rb`:

Add near the top of the class:

```ruby
    # If a changed constant is referenced by more than this share of all spec
    # files, a full re-run is cheaper and simpler than a giant partial one.
    REFERENCE_FULL_RATIO = 0.5
```

In `compute`, change the source-file branch (the `else` arm) to collect candidates — note `added` files now also contribute:

```ruby
        else
          abs = File.join(root, rel)
          drop_source_files << abs if deleted
          unless added
            rerun_example_ids.concat(coverage_map.examples_covering_file(abs))
          end
          unless deleted
            candidates = newly_covering_candidates(root: root, rel: rel, coverage_map: coverage_map)
            return FULL if candidates == :full
            rerun_spec_files.concat(candidates)
          end
        end
```

Add the class methods (below `full_trigger?`):

```ruby
    # #11: an unchanged spec file can START covering a changed source file
    # because of the edit itself. Cheap static detection: spec files that
    # textually reference a constant the changed file defines, but currently
    # contribute zero coverage to it, get re-run. Files already covering it
    # are handled example-by-example via rerun_example_ids.
    def self.newly_covering_candidates(root:, rel:, coverage_map:)
      abs = File.join(root, rel)
      return [] unless File.exist?(abs)

      constants = DefinedConstants.in_source(File.read(abs))
      return [] if constants.empty?

      all_specs = Dir[File.join(root, "spec/**/*_spec.rb")]
      return [] if all_specs.empty?

      covering_specs = coverage_map.examples_covering_file(abs)
                                   .map { |id| spec_file_of(id) }.to_a.uniq
      pattern = /\b(?:#{constants.map { |c| Regexp.escape(c) }.join("|")})\b/
      candidates = all_specs.filter_map do |spec_abs|
        spec_rel = spec_abs.delete_prefix("#{root.chomp("/")}/")
        next if covering_specs.include?(spec_rel)
        spec_rel if File.read(spec_abs).match?(pattern)
      end
      if candidates.size > all_specs.size * REFERENCE_FULL_RATIO
        # Never silently degrade: a full baseline where the user expected an
        # incremental refresh must be explained, or it looks like a hang.
        warn "active_mutator: constant-reference scan matched #{candidates.size} of " \
             "#{all_specs.size} spec files for #{rel}; falling back to full baseline"
        return :full
      end

      candidates
    end

    def self.spec_file_of(example_id)
      example_id.sub(%r{\A\./}, "").sub(/\[.*\]\z/, "")
    end
```

Run the delta spec → PASS. Also confirm every pre-existing example in the file still passes (the fake root `"/project"` has no files on disk, so `newly_covering_candidates` returns `[]` there — behavior unchanged).

- [ ] **Step 3: Measure and bound the hot-path cost**

The scan runs on the incremental path for every changed source file — bench (force-baseline + warm cache) never exercises it, so measure it directly on this repo's own suite, which is the largest corpus at hand:

```bash
ruby -Ilib -e '
  require "active_mutator"
  rel = "lib/active_mutator/runner.rb"
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  constants = ActiveMutator::DefinedConstants.in_source(File.read(rel))
  pattern = /\b(?:#{constants.map { |c| Regexp.escape(c) }.join("|")})\b/
  hits = Dir["spec/**/*_spec.rb"].count { |f| File.read(f).match?(pattern) }
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
  puts "#{hits} referencing spec files, scan took #{ms}ms"
'
```

Acceptance bound: **< 50ms** on this repo (~25 spec files; the cost is one read + one regex match per spec file, linear in total spec bytes and independent of suite runtime). Record the measured number in `docs/dogfood-log.md` alongside the Task 4 row. Then confirm the same order of magnitude on payint (thousands of spec files) by running the same one-liner from the payint root with `rel` set to any `app/models` file — expect tens-to-hundreds of ms, i.e. noise next to the multi-second partial `bundle exec rspec` boot the delta triggers anyway. If payint measures > 1s, add an mtime-keyed content cache as a follow-up issue rather than blocking this task — but record the number either way.

- [ ] **Step 4: Full gates + commit**

```bash
bundle exec rspec
bundle exec exe/active_mutator lib --changed
git add lib/active_mutator/baseline_delta.rb spec/active_mutator/baseline_delta_spec.rb docs/dogfood-log.md
git commit -m "feat: delta refresh re-runs constant-referencing non-covering spec files

Refs #11"
```

---

# Task 10 — End-to-end proof of the blind-spot fix + docs (#11)

**Files:**
- Modify: `spec/active_mutator/baseline_refresh_spec.rb` (or a new example alongside its existing style — it exercises `Baseline#coverage_map` against a real tmp project)
- Modify: `docs/guides/how-it-works.md`, `README.md`

- [ ] **Step 1: Failing integration spec**

Add to `spec/active_mutator/baseline_refresh_spec.rb`, following that file's existing setup (it builds a real tmp project and runs `Baseline#coverage_map`; reuse its project-scaffolding helper — do not duplicate scaffolding):

```ruby
it "picks up a newly-covering example from an unchanged spec file (#11)" do
  # Arrange: two spec files. widget_spec covers Widget#size. helper_spec
  # references Widget but its example takes an early-return path that does
  # NOT execute lib/widget.rb, so it owns no coverage of it.
  # (Exact file contents follow the file's existing fixture-writing helper:)
  write("lib/widget.rb", <<~RUBY)
    class Widget
      def size = 1
    end
  RUBY
  write("spec/widget_spec.rb", <<~RUBY)
    require_relative "../lib/widget"
    RSpec.describe Widget do
      it("has a size") { expect(Widget.new.size).to eq(1) }
    end
  RUBY
  write("spec/helper_spec.rb", <<~RUBY)
    RSpec.describe "helper" do
      it "only touches Widget when the flag file exists" do
        if File.exist?(File.expand_path("../flag", __dir__))
          require_relative "../lib/widget"
          expect(Widget.new.size).to eq(1)
        else
          expect(true).to be(true)
        end
      end
    end
  RUBY
  baseline = ActiveMutator::Baseline.new(root: root)
  first = baseline.coverage_map
  expect(first.examples_covering_file(File.join(root, "lib/widget.rb")).map { |id| id[/spec\/\w+_spec/] }.uniq)
    .to eq(["spec/widget_spec"])

  # Act: edit ONLY the source file; simultaneously the helper example starts
  # covering it (flag file flips its branch). helper_spec.rb itself is unchanged.
  write("flag", "")
  write("lib/widget.rb", <<~RUBY)
    class Widget
      def size = 2
    end
  RUBY
  write("spec/widget_spec.rb", <<~RUBY)
    require_relative "../lib/widget"
    RSpec.describe Widget do
      it("has a size") { expect(Widget.new.size).to eq(2) }
    end
  RUBY

  refreshed = ActiveMutator::Baseline.new(root: root).coverage_map
  covering = refreshed.examples_covering_file(File.join(root, "lib/widget.rb"))
  expect(covering.map { |id| id[/spec\/\w+_spec/] }.uniq.sort)
    .to eq(["spec/helper_spec", "spec/widget_spec"])
  expect(ActiveMutator::Baseline.new(root: root)).to be_truthy # cache remained partial-refreshable
end
```

Adjust mechanics to the file's real helper names when writing it (the file already has a tmp-project pattern and `flag`-free scaffolding; keep the two-spec-file + flag-flip structure and assertions exactly). Note `spec/widget_spec.rb` changes too (the expectation must track the new value) — that alone would re-run widget_spec but NOT helper_spec, which is precisely the blind spot: **before Task 9 this example fails** because helper_spec is never re-run. Run it against `git stash`-ed Task 9 if you want proof, or just:

```bash
bundle exec rspec spec/active_mutator/baseline_refresh_spec.rb
```
Expected now (Task 9 merged): PASS. If it fails, debug Task 9 — do not weaken the assertion.

- [ ] **Step 2: Update the docs**

`docs/guides/how-it-works.md` — rewrite the blind-spot passage (lines ~142–158) to say: the delta refresh now *also* re-runs unchanged spec files that reference a constant defined in the changed source file but currently contribute zero coverage to it (word-boundary text match on Prism-extracted **fully qualified** class/module names, full-run fallback above 50% of spec files with a stderr warning when it trips). State the **residual** gap precisely — three cases, all still recovered by nightly `--force-baseline`: an example that newly covers the change *without any textual reference to its constants* (pure indirection); a partially-covering spec file whose other examples newly cover; and a spec file referencing a *nested* constant by bare leaf name only (leaf shorthand is deliberately not matched — see `DefinedConstants`). Update the summary bullet at line ~320 the same way. Update the two `README.md` mentions (lines ~241 and ~302) from "recovers the blind spot" to "recovers the residual blind spot (constant-reference detection handles the common case since 0.2)".

- [ ] **Step 3: Full gates + bench + commit**

```bash
bundle exec rspec
ACTIVE_MUTATOR_E2E=1 bundle exec rspec spec/e2e
bundle exec exe/active_mutator lib --changed
bin/bench --out /tmp/bench-post11
bin/bench-diff bench/baselines/tiny_project-jobs2.mutation-report.json \
               /tmp/bench-post11/tiny_project-jobs2/mutation-report.json
```
Expected: all green, bench-diff exit 0, and compare `/tmp/bench-post11/*/bench.json` `mutation_seconds` against the Task 4 row — no material regression (the reference scan runs only on delta refreshes of changed source files; the bench flow is force-baseline + warm-cache, so it must be unaffected).

```bash
git add spec/active_mutator/baseline_refresh_spec.rb docs/guides/how-it-works.md README.md
git commit -m "test+docs: prove and document the newly-covering-example fix

Closes #11"
```

---

# Task 11 — Phase 4 close-out

- [ ] **Step 1: Full self-mutation run (not `--changed`)**

```bash
bundle exec exe/active_mutator lib
```
Expected: exit 0, or every survivor triaged by writing a killing test (NEVER by editing the ledger or running `--accept-survivors`).

- [ ] **Step 2: Dogfood on payint**

```bash
cd ~/Documents/enovis/payint   # branch: active-mutator-poc
bundle exec active_mutator app/models --subject "Document#size_category"   # smoke
bundle exec active_mutator --changed                                        # adaptive timeouts live
```
Record wall time + score rows in `docs/dogfood-log.md`; note whether the timeout count dropped versus the Phase 3 row (that is #9's acceptance signal on real load).

- [ ] **Step 3: Issue hygiene**

`Closes #21` (Task 3), `Closes #9` (Task 7), `Closes #11` (Task 10) are already in the commit messages; verify each issue auto-closes on merge or close manually with a comment linking the commit. Comment on #21 noting the git-pinned external-target support and that adding external corpus rows is a data-only follow-up.

- [ ] **Step 4: Commit the dogfood log**

```bash
cd ~/Documents/enovis/active_mutator
git add docs/dogfood-log.md
git commit -m "docs: phase 4 dogfood results"
```

---

## Self-review

**Coverage vs the three issues:**
- **#21** — pinned corpus (committed fixtures + git/SHA target type), matrix over `--jobs` (and any flag, e.g. `timeout_factor`) per `targets.json`, Stryker JSON + terminal capture (`exec.log`, per-cell stdout in the log) saved per cell, per-stage wall times (baseline vs mutation via the `--max-mutants 0` trick) and mutant counts (in the Stryker report), cross-run differ with score delta, status transitions, added/removed mutants. Deviation (external SHA-pinned repos not seeded) is declared in the header with rationale. Per-operator wall-time delta from the issue is **not** delivered: per-mutant timing does not exist in the Stryker report or anywhere in the runtime today; adding it is runtime work out of #21's "no runtime path changes" lane — flagged here honestly, follow-up candidate once #17's report carries timing extras.
- **#9** — observed actual-vs-estimate ratio from finished workers (issue text), sampled from **killed forks only** (errors finish artificially fast, survivors run the whole covering set, timeouts have no known wall time — each exclusion stated and spec'd), utilization measured against the **effective budget the fork ran under** (ratchet-proof; recovery spec'd in Task 5), **one calibrator per lane** so parallel-load medians never scale serial budgets, warm-up N=5, running median, clamp 0.5–4 (roadmap), serial-lane `browser_boot_seconds` stays additive (roadmap), static flags remain as the starting budget and `--no-adaptive-timeout` restores exact pre-#9 behavior (backward compat), effective budgets surfaced via the once-per-change `adaptive timeout scale` stderr line (spec'd), acceptance measured on the deterministic bench gate (cells run `--no-adaptive-timeout`, Task 7 Steps 4/6) plus a manual adaptive fixture run, and payint dogfood (Task 11).
- **#11** — "cheap detection of coverage-set growth" delivered as constant-reference scanning of currently-non-covering spec files using **fully qualified names only** (common bare leaves like `Config` deliberately excluded, with a delta-level spec for exactly that case), a >50% full-run safety valve that **warns on stderr** when it trips (spec'd), zero disk work when nothing changed, hot-path cost measured and bounded on this repo and payint (Task 9 Step 3), integration proof that the pre-fix behavior fails (Task 10 spec is the exact blind-spot scenario from how-it-works.md), the three residual gaps documented, `--force-baseline` guidance updated rather than removed. Parse boundary pinned: errors blank `DefinedConstants` output, warnings do not (both spec'd with in-spec preconditions on the fixture).

**Placeholder scan:** no "TBD"/"similar to Task N". Two intentional soft spots, both bounded and justified: Task 6 Step 1 and Task 10 Step 1 tell the worker to reuse the existing spec file's helpers/scaffolding instead of pasting duplicates — the assertions, fixture semantics, and expected values are fully specified; only the helper names come from the file being edited. Task 4's dogfood-log row has `<fill from bench.json>` for measured wall times, which cannot be known before the run by definition.

**Type/name consistency:** `TimeoutCalibrator` API is `record(elapsed_seconds, budget)`, `budget_for(item)`, `warmed?`, `scale` — used with exactly these signatures in Task 5's specs/implementation, Task 6's scheduler (`calibrator_for(item)&.record(now - entry[:started], entry[:budget])`), and Task 6's `fake_calibrator` stub. The Scheduler keyword is `calibrators:` (a `{parallel:, serial:}` hash) everywhere: Task 6 helper, Task 6 implementation, Task 7 Runner wiring and its three specs. `WorkItem` fields `variable`/`boot_extra` introduced and default-pinned in Task 5 (`work_item_spec.rb`), populated in Task 6 Step 2, consumed by the calibrator math. Config field `adaptive_timeout` spelled identically in `Config`, CLI defaults, `--[no-]adaptive-timeout`, config-file `:boolean` key, Runner, and the bench matrix key. **Config.new call sites audited in Task 7 Step 2** (exactly two; the one with explicit keywords gets the exact edit shown). `Bench::Plan::Cell` fields (`id, target_name, type, path, git_url, git_sha, argv`) match between Task 2's implementation and Task 3's specs; Task 7 Step 4's `flag_argv`/`adaptive_default` revision updates Task 2's argv expectations in the same step. `DefinedConstants.in_source` name matches Tasks 8 and 9. `newly_covering_candidates` returns `[]` / list / `:full`, and `compute` handles all three.

**Determinism audit:** the bench-diff exit-0 gate only ever runs cells with static budgets (`--no-adaptive-timeout` appended by default from Task 7 Step 4 onward; before Task 7 the flag doesn't exist and static is the only behavior) — Killed↔Timeout flips cannot make the gate intermittently red. Adaptive behavior is exercised by unit/scheduler specs with stubbed calibrators (no wall-clock dependence) and eyeballed via the manual fixture run in Task 7 Step 6.

**Ordering:** #21 lands first and pins a baseline (Task 4) precisely so #9 (Task 7 Step 6) and #11 (Task 10 Step 3) are gated by a regression diff — the roadmap's rationale ("#21 gates the other two") is preserved.
