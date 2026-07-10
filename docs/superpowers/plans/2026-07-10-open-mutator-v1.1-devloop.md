# open_mutator v1.1 Dev-Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1.1 — hot-parent fork sharing with a serial browser lane, incremental baseline (cache v2 + delta refresh), and dev-loop integration (`--changed`, acceptance ledger, mutation-check skill).

**Architecture:** Three workstreams on top of the shipped v1 pipeline. (1) Parent preloads the project's spec helper once and disarms SimpleCov; workers filter `RSpec.world` to covering-file groups only (leaked helper-load groups cause false kills). Work items get a `lane`; browser-covered mutants run serially after the parallel lane. (2) Coverage cache becomes v2 (primary per-example `records`, inverted map derived at load); a `BaselineDelta` decides between surgical partial re-runs and the full-run fallback; all cache/ledger writes are flock-guarded and atomic. (3) `SinceFilter` learns untracked files, `--changed` aliases `--since HEAD`, and a repo-root committed acceptance ledger (fingerprints with duplicate-ordinals) adds the `accepted` status.

**Tech Stack:** Ruby ≥ 3.2, prism, rspec-core, stdlib only (json, digest, etc). Existing suite: 125 default examples green; tags `:integration`, `:e2e`, `:rails_e2e`.

**Spec:** `docs/superpowers/specs/2026-07-10-open-mutator-v1.1-devloop-design.md`

---

## File structure

```
lib/open_mutator/atomic_file.rb        # NEW — flock + tmp-rename writes
lib/open_mutator/baseline_delta.rb     # NEW — digest diff → Delta decision
lib/open_mutator/fingerprint.rb        # NEW — Fingerprint + ordinal computation
lib/open_mutator/accepted_ledger.rb    # NEW — repo-root committed ledger
lib/open_mutator/runner.rb             # MOD — spec-helper preload, SimpleCov disarm, ENV flag, lanes, ledger integration
lib/open_mutator/worker.rb             # MOD — world-group filtering
lib/open_mutator/work_item.rb          # MOD — lane field
lib/open_mutator/scheduler.rb          # MOD — lane-aware two-pass run
lib/open_mutator/baseline_hooks.rb     # MOD — v2 payload (records primary)
lib/open_mutator/coverage_map.rb       # MOD — v2 load, records API
lib/open_mutator/baseline.rb           # MOD — delta refresh, expanded digests, atomic writes
lib/open_mutator/since_filter.rb       # MOD — untracked whole-file sentinel
lib/open_mutator/config.rb             # MOD — new fields
lib/open_mutator/cli.rb                # MOD — new flags
lib/open_mutator/result.rb             # MOD — :accepted status
lib/open_mutator/reporter/terminal.rb  # MOD — accepted char/count
lib/open_mutator/reporter/json.rb      # MOD — accepted + exit_reason
spec/support/fixture_copy.rb           # NEW — tmpdir copies of tiny_project
docs/skills/mutation-check.md          # NEW — agent-facing skill
README.md                              # NEW
```

**Canonical signatures (later tasks must match):**

```ruby
Config   = Data.define(:paths, :since, :subject_filter, :jobs, :format, :requires,
                       :timeout_factor, :timeout_floor, :force_baseline, :root,
                       :preload_helper, :serial_patterns, :browser_boot_seconds,
                       :accept_survivors)
# preload_helper: nil (auto-detect) | String (path) | :none
WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane)   # lane: :parallel | :serial
Fingerprint = Data.define(:file, :subject, :description, :original_snippet, :ordinal)
Delta    = Data.define(:full, :rerun_spec_files, :rerun_example_ids,
                       :drop_example_ids, :drop_source_files) { def full? = full }

AtomicFile.write(path, content)                       → nil (flock + tmp + rename)
BaselineDelta.compute(old_digests:, new_digests:, coverage_map:, root:) → Delta
Fingerprint.for_mutations(mutations, root:)           → {mutation => Fingerprint} (ordinal by edit-range order)
AcceptedLedger.load(root)  → ledger; #accepted?(fp) → bool; #accept!(new_fps, all_current_fps) → nil; #stale_entries(all_current_fps) → [Hash]
CoverageMap: #version → Integer|nil; #records → Hash; #examples_covering_file(abs_path) → [id];
             #examples_for_spec_file(rel_path) → [id]; existing #examples_for/#time_for/#fresh? unchanged in signature
Scheduler#run(items) — internally: parallel-lane pool at @jobs, then serial-lane pool at 1
Worker — runs only world groups whose metadata[:absolute_file_path] is a covering spec file
Result statuses: :killed :survived :timeout :error :uncovered :accepted
```

Status char map (Terminal): killed `.`, survived `S`, timeout `T`, error `E`, uncovered `U`, accepted `A`.

---

# Phase 1 — Hot parent & serial lane

## Task 1: Config/CLI fields + ENV flag + spec-helper preload + SimpleCov disarm

**Files:**
- Modify: `lib/open_mutator/config.rb`, `lib/open_mutator/cli.rb`, `lib/open_mutator/runner.rb`
- Test: `spec/open_mutator/cli_spec.rb`, `spec/open_mutator/runner_spec.rb`

- [x] **Step 1: Write the failing tests**

Append to the `.parse` describe block in `spec/open_mutator/cli_spec.rb`:
```ruby
    it "defaults the v1.1 fields" do
      config = described_class.parse([])
      expect(config.preload_helper).to be_nil
      expect(config.serial_patterns).to eq(["spec/system/", "spec/features/"])
      expect(config.browser_boot_seconds).to eq(15.0)
      expect(config.accept_survivors).to be(false)
    end

    it "parses the v1.1 flags" do
      config = described_class.parse(
        %w[--preload-helper spec/other_helper.rb --serial-pattern spec/browser/
           --browser-boot-seconds 30 --accept-survivors]
      )
      expect(config.preload_helper).to eq("spec/other_helper.rb")
      expect(config.serial_patterns).to eq(["spec/browser/"])
      expect(config.browser_boot_seconds).to eq(30.0)
      expect(config.accept_survivors).to be(true)
    end

    it "parses --no-preload-helper as :none" do
      expect(described_class.parse(%w[--no-preload-helper]).preload_helper).to eq(:none)
    end
```

New describe block in `spec/open_mutator/runner_spec.rb` (inside the top-level describe; note `config` there must gain the new fields — replace the existing `let(:config)` with):
```ruby
  let(:config) do
    OpenMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: "/project", preload_helper: nil, serial_patterns: ["spec/system/", "spec/features/"],
      browser_boot_seconds: 15.0, accept_survivors: false
    )
  end
```
and append:
```ruby
  describe "#preload_spec_helper!" do
    it "requires rails_helper when present, in preference order" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec", "rails_helper.rb"), "$rails_helper_loaded = true")
        File.write(File.join(dir, "spec", "spec_helper.rb"), "$spec_helper_loaded = true")
        runner = described_class.new(config.with(root: dir))
        runner.send(:preload_spec_helper!)
        expect($rails_helper_loaded).to be(true)
        expect($spec_helper_loaded).to be_nil
      ensure
        $rails_helper_loaded = $spec_helper_loaded = nil
      end
    end

    it "does nothing for :none" do
      runner = described_class.new(config.with(preload_helper: :none, root: "/nonexistent"))
      expect { runner.send(:preload_spec_helper!) }.not_to raise_error
    end

    it "disarms SimpleCov after preload" do
      fake = Class.new do
        def self.at_exit_calls = @at_exit_calls ||= []
        def self.at_exit(&blk) = at_exit_calls << blk
      end
      stub_const("SimpleCov", fake)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec", "spec_helper.rb"), "# empty")
        described_class.new(config.with(root: dir)).send(:preload_spec_helper!)
      end
      expect(fake.at_exit_calls.size).to eq(1)
    end
  end
```
Add `require "tmpdir"` and `require "fileutils"` at the top of `runner_spec.rb`.

- [x] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/cli_spec.rb spec/open_mutator/runner_spec.rb`
Expected: FAIL — `Data.define` raises `ArgumentError: missing keyword` (Config lacks fields) and `NoMethodError` for `preload_spec_helper!`

- [x] **Step 3: Implement**

Replace `lib/open_mutator/config.rb` body:
```ruby
require "etc"

module OpenMutator
  Config = Data.define(:paths, :since, :subject_filter, :jobs, :format, :requires,
                       :timeout_factor, :timeout_floor, :force_baseline, :root,
                       :preload_helper, :serial_patterns, :browser_boot_seconds,
                       :accept_survivors)
end
```

In `lib/open_mutator/cli.rb`, extend the defaults hash and parser:
```ruby
      options = {
        # Half the cores, not all of them: each worker pays full RSpec setup,
        # and system-spec workers boot a browser + app server. Full-core
        # oversubscription starves workers of CPU and turns slow-but-honest
        # kills into false timeouts (observed on a real Rails monolith).
        since: nil, subject_filter: nil, jobs: [Etc.nprocessors / 2, 1].max,
        format: :terminal,
        # Budgets derive from baseline times measured warm and unloaded; the
        # factor must absorb parallel-load slowdown, and the floor the fork's
        # boot cost (RSpec setup + spec file loading).
        requires: [], timeout_factor: 8.0, timeout_floor: 10.0, force_baseline: false,
        preload_helper: nil, serial_patterns: ["spec/system/", "spec/features/"],
        browser_boot_seconds: 15.0, accept_survivors: false
      }
```
and add options (inside the OptionParser block, after `--timeout-floor`):
```ruby
        o.on("--preload-helper FILE", "Spec helper to preload in the parent (default: auto-detect)") { |v| options[:preload_helper] = v }
        o.on("--no-preload-helper", "Skip spec-helper preload") { options[:preload_helper] = :none }
        o.on("--serial-pattern PAT", "Covering-path prefix that forces the serial lane (repeatable; replaces defaults on first use)") do |v|
          options[:serial_patterns] = [] unless options[:serial_patterns_replaced]
          options[:serial_patterns_replaced] = true
          options[:serial_patterns] << v
        end
        o.on("--browser-boot-seconds S", Float, "Extra timeout budget for serial-lane mutants") { |v| options[:browser_boot_seconds] = v }
        o.on("--accept-survivors", "Record surviving mutants into the acceptance ledger") { options[:accept_survivors] = true }
```
Before `Config.new(...)`, drop the bookkeeping key: `options.delete(:serial_patterns_replaced)`.

In `lib/open_mutator/runner.rb`:
- In `#call`, first line: `ENV["OPEN_MUTATOR"] = "1"` and after `preload!` add `preload_spec_helper!`.
- Add private methods:
```ruby
    def preload_spec_helper!
      return if @config.preload_helper == :none

      helper = if @config.preload_helper
                 File.expand_path(@config.preload_helper, @config.root)
               else
                 %w[spec/rails_helper.rb spec/spec_helper.rb]
                   .map { |p| File.join(@config.root, p) }
                   .find { |p| File.exist?(p) }
               end
      return unless helper && File.exist?(helper)

      require helper
      disarm_simplecov
    end

    # A preloaded helper commonly starts SimpleCov. Its at_exit would fire in
    # THIS parent process at the end of the mutation run, clobbering the
    # project's real coverage data — and minimum_coverage would exit(1) for a
    # bogus reason. Neutralize it.
    def disarm_simplecov
      SimpleCov.at_exit {} if defined?(SimpleCov)
    end
```

- [x] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/cli_spec.rb spec/open_mutator/runner_spec.rb`
Expected: PASS (cli 6, runner 5)

- [x] **Step 5: Full suite, commit**

Run: `bundle exec rspec` — all green.
```bash
git add -A && git commit -m "feat: spec-helper parent preload, SimpleCov disarm, v1.1 config"
```

## Task 2: Worker world-group filtering

**Files:**
- Modify: `lib/open_mutator/worker.rb`
- Test: `spec/open_mutator/worker_spec.rb`

- [x] **Step 1: Write the failing test**

Append inside the describe block of `spec/open_mutator/worker_spec.rb`:
```ruby
  it "runs only groups belonging to covering spec files (drops helper-leaked groups)" do
    covering = instance_double(RSpec::Core::ExampleGroup,
                               metadata: { absolute_file_path: File.expand_path("spec/x_spec.rb") })
    leaked = instance_double(RSpec::Core::ExampleGroup,
                             metadata: { absolute_file_path: File.expand_path("spec/support/leaky.rb") })
    allow(RSpec.world).to receive(:ordered_example_groups).and_return([leaked, covering])
    ran_groups = nil
    allow(rspec_runner).to receive(:run_specs) { |groups| ran_groups = groups; 0 }
    run_worker
    expect(ran_groups).to eq([covering])
  end
```
(The existing `before` block already stubs `ordered_example_groups` with `[]`; the `allow` here overrides it for this example. `run_worker` passes `["spec/x_spec.rb[1:1]"]` — unchanged.)

- [x] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/open_mutator/worker_spec.rb`
Expected: the new example FAILS — `ran_groups` is `[leaked, covering]`

- [x] **Step 3: Implement**

In `lib/open_mutator/worker.rb`, replace the `run_specs` line in `#run`:
```ruby
      code = runner.run_specs(covering_groups)
```
and add a private method:
```ruby
    # RSpec.world holds every group registered in the process — including any
    # top-level groups evaluated while the PARENT preloaded the spec helper
    # (spec/support files with RSpec.describe at load time are common). Those
    # leak into the fork; running them would report their failures as false
    # kills. Run only groups that belong to the covering spec files.
    def covering_groups
      covering = @example_ids
                 .map { |id| File.expand_path(id[/\A(.+?)\[/, 1]) }
                 .to_set
      RSpec.world.ordered_example_groups.select do |group|
        covering.include?(group.metadata[:absolute_file_path])
      end
    end
```
Add `require "set"` at the top of the file.

- [x] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/worker_spec.rb`
Expected: 5 examples, 0 failures

- [x] **Step 5: Full suite, commit**

Run: `bundle exec rspec` — green.
```bash
git add -A && git commit -m "feat: worker runs only covering-file example groups"
```

## Task 3: Serial lane (WorkItem.lane, lane-aware Scheduler, Runner partition)

**Files:**
- Modify: `lib/open_mutator/work_item.rb`, `lib/open_mutator/scheduler.rb`, `lib/open_mutator/runner.rb`
- Test: `spec/open_mutator/scheduler_spec.rb`, `spec/open_mutator/runner_spec.rb`

- [x] **Step 1: Write the failing tests**

In `spec/open_mutator/scheduler_spec.rb`, change the `item` helper and add a lane test:
```ruby
  def item(timeout: 5.0, lane: :parallel)
    OpenMutator::WorkItem.new(mutation: nil, example_ids: [], timeout: timeout, lane: lane)
  end
```
```ruby
  it "runs serial-lane items one at a time, after the parallel lane" do
    order = Queue.new
    worker = lambda do |_m, _e, writer|
      order << :start
      sleep 0.1
      order << :finish
      writer.puts(JSON.generate("status" => "killed", "details" => nil))
    end
    scheduler(worker: worker, jobs: 2).run([item(lane: :serial), item(lane: :serial)])
    events = Array.new(4) { order.pop }
    expect(events).to eq(%i[start finish start finish]) # never two concurrent starts
  end
```

In `spec/open_mutator/runner_spec.rb`, replace the existing `plan_work` example with a lane-aware version (the covered mutation should land in `:parallel`; add a browser-covered one):
```ruby
  it "builds work items with lanes and reports uncovered ones" do
    covered = mutation(line: 2)
    uncovered = mutation(line: 3)
    map = instance_double(OpenMutator::CoverageMap)
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", 2..2).and_return(["./spec/a_spec.rb[1:1]"])
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", 3..3).and_return([])
    allow(map).to receive(:time_for).and_return(0.5)

    items, uncovered_results = described_class.new(config).plan_work([covered, uncovered], map)

    expect(items.size).to eq(1)
    expect(items.first.lane).to eq(:parallel)
    expect(items.first.timeout).to eq(0.5 * 4.0 + 2.0)
    expect(uncovered_results.map(&:status)).to eq([:uncovered])
  end

  it "assigns the serial lane and budget bump to browser-covered mutants" do
    m = mutation(line: 2)
    map = instance_double(OpenMutator::CoverageMap)
    allow(map).to receive(:examples_for)
      .and_return(["./spec/system/extractions_spec.rb[1:1]", "./spec/a_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(1.0)

    items, = described_class.new(config).plan_work([m], map)
    expect(items.first.lane).to eq(:serial)
    expect(items.first.timeout).to eq(1.0 * 4.0 + 2.0 + 15.0)
  end
```

- [x] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/scheduler_spec.rb spec/open_mutator/runner_spec.rb`
Expected: FAIL — WorkItem has no `lane` keyword

- [x] **Step 3: Implement**

`lib/open_mutator/work_item.rb`:
```ruby
module OpenMutator
  # lane: :parallel (default pool) | :serial (browser-covered, one at a time)
  WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane)
end
```

`lib/open_mutator/scheduler.rb` — replace `#run` with a lane-aware version (keep everything else):
```ruby
    def run(items)
      previous_traps = nil
      running = {}
      previous_traps = install_signal_handlers(running)
      results = []
      # Browser-covered mutants each boot Chrome + an app server; running them
      # concurrently melts CPUs and manufactures false timeouts. Parallel lane
      # first at full width, then the serial lane one at a time.
      results.concat(run_pool(items.select { |i| i.lane == :parallel }, @jobs, running))
      results.concat(run_pool(items.select { |i| i.lane == :serial }, 1, running))
      results
    ensure
      restore_traps(previous_traps) if previous_traps
    end

    private

    def run_pool(items, width, running)
      queue = items.dup
      results = []
      until queue.empty? && running.empty?
        spawn(queue.shift, running) while running.size < width && !queue.empty?
        reap(running, results)
        sleep 0.02 unless running.empty?
      end
      results
    end
```
(`spawn`/`reap`/`finish`/`kill`/trap methods unchanged; `running` is now created in `run` and passed through so the signal handler closure keeps working.)

`lib/open_mutator/runner.rb` — in `plan_work`, replace the item-building branch:
```ruby
        else
          lane = example_ids.any? { |id| serial_example?(id) } ? :serial : :parallel
          timeout = map.time_for(example_ids) * @config.timeout_factor + @config.timeout_floor
          timeout += @config.browser_boot_seconds if lane == :serial
          items << WorkItem.new(mutation: mutation, example_ids: example_ids, timeout: timeout, lane: lane)
        end
```
and add private:
```ruby
    def serial_example?(example_id)
      path = example_id.sub(%r{\A\./}, "")
      @config.serial_patterns.any? { |pattern| path.start_with?(pattern) }
    end
```

- [x] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/scheduler_spec.rb spec/open_mutator/runner_spec.rb`
Expected: PASS (scheduler 6, runner 6)

- [x] **Step 5: Full suite (twice, seeds differ), commit**

Run: `bundle exec rspec && bundle exec rspec` — green both.
```bash
git add -A && git commit -m "feat: serial lane for browser-covered mutants"
```

---

# Phase 2 — Cache v2 & incremental baseline

## Task 4: Cache v2 payload + CoverageMap v2

**Files:**
- Modify: `lib/open_mutator/baseline_hooks.rb`, `lib/open_mutator/coverage_map.rb`
- Test: `spec/open_mutator/baseline_hooks_spec.rb`, `spec/open_mutator/coverage_map_spec.rb`

- [ ] **Step 1: Write the failing tests**

In `spec/open_mutator/baseline_hooks_spec.rb`, replace the `.build_payload` example:
```ruby
  describe ".build_payload" do
    it "emits version-2 primary records" do
      records = { "spec/a_spec.rb[1:1]" => [["/root/lib/a.rb", 3]] }
      times = { "spec/a_spec.rb[1:1]" => 0.5 }
      payload = described_class.build_payload(records, times)
      expect(payload["version"]).to eq(2)
      expect(payload["records"]).to eq(records)
      expect(payload["times"]).to eq(times)
      expect(payload).not_to have_key("map")
    end
  end
```

Replace `spec/open_mutator/coverage_map_spec.rb` wholesale:
```ruby
require "tmpdir"
require "json"

RSpec.describe OpenMutator::CoverageMap do
  subject(:map) do
    described_class.new(
      "version" => 2,
      "records" => {
        "./spec/a_spec.rb[1:1]" => [["/root/lib/a.rb", 3], ["/root/lib/a.rb", 4]],
        "./spec/b_spec.rb[1:1]" => [["/root/lib/a.rb", 3], ["/root/lib/b.rb", 9]]
      },
      "times" => { "./spec/a_spec.rb[1:1]" => 0.5, "./spec/b_spec.rb[1:1]" => 0.25 },
      "digests" => { "lib/a.rb" => "abc" }
    )
  end

  it "derives the inverted index from records" do
    expect(map.examples_for("/root/lib/a.rb", 3..4))
      .to contain_exactly("./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]")
    expect(map.examples_for("/root/lib/b.rb", 9..9)).to eq(["./spec/b_spec.rb[1:1]"])
    expect(map.examples_for("/root/lib/a.rb", 99..99)).to eq([])
  end

  it "sums known example times, treating nil as zero" do
    expect(map.time_for(["./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]", "unknown"])).to eq(0.75)
    nil_map = described_class.new("version" => 2, "records" => {},
                                  "times" => { "x" => nil }, "digests" => {})
    expect(nil_map.time_for(["x"])).to eq(0.0)
  end

  it "is stale when digests differ or version is not 2" do
    expect(map.fresh?("lib/a.rb" => "abc")).to be(true)
    expect(map.fresh?("lib/a.rb" => "zzz")).to be(false)
    v1 = described_class.new("map" => {}, "times" => {}, "digests" => {})
    expect(v1.version).to be_nil
    expect(v1.fresh?({})).to be(false)
  end

  it "finds examples covering a source file" do
    expect(map.examples_covering_file("/root/lib/b.rb")).to eq(["./spec/b_spec.rb[1:1]"])
  end

  it "finds examples belonging to a spec file" do
    expect(map.examples_for_spec_file("spec/a_spec.rb")).to eq(["./spec/a_spec.rb[1:1]"])
  end

  it "loads from a JSON file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "coverage.json")
      File.write(path, JSON.generate("version" => 2, "records" => {}, "times" => {}, "digests" => {}))
      expect(described_class.load(path).examples_for("/x.rb", 1..1)).to eq([])
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/baseline_hooks_spec.rb spec/open_mutator/coverage_map_spec.rb`
Expected: FAIL (payload shape, missing methods)

- [ ] **Step 3: Implement**

In `lib/open_mutator/baseline_hooks.rb`, replace `build_payload`:
```ruby
    def self.build_payload(records, times)
      { "version" => 2, "records" => records, "times" => times }
    end
```

Replace `lib/open_mutator/coverage_map.rb`:
```ruby
require "json"

module OpenMutator
  # Cache format v2: primary data is per-example `records`
  # ({example_id => [[abs_path, line], ...]}); the inverted index is derived
  # in memory at load. A missing/old version is simply stale — the cache is
  # disposable, so there is no migration path, only regeneration.
  class CoverageMap
    def self.load(path) = new(JSON.parse(File.read(path)))

    attr_reader :version, :records

    def initialize(data)
      @version = data["version"]
      @records = data.fetch("records", {})
      @times = data.fetch("times", {})
      @digests = data.fetch("digests", {})
      @map = build_map
    end

    def examples_for(file, lines)
      lines.flat_map { |line| @map.fetch("#{file}:#{line}", []) }.uniq.sort
    end

    def time_for(example_ids)
      # `|| 0.0`, not fetch-with-default: a key present with nil value must
      # also coerce to zero, or Runner#plan_work explodes with TypeError.
      example_ids.sum { |id| @times[id] || 0.0 }
    end

    def fresh?(digests) = @version == 2 && @digests == digests

    def examples_covering_file(abs_path)
      @records.filter_map do |example_id, hits|
        example_id if hits.any? { |(path, _line)| path == abs_path }
      end
    end

    def examples_for_spec_file(rel_spec_path)
      @records.keys.select do |example_id|
        example_id.sub(%r{\A\./}, "").start_with?("#{rel_spec_path}[")
      end
    end

    private

    def build_map
      map = Hash.new { |h, k| h[k] = [] }
      @records.each do |example_id, hits|
        hits.each { |(path, line)| map["#{path}:#{line}"] << example_id }
      end
      map
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/baseline_hooks_spec.rb spec/open_mutator/coverage_map_spec.rb`
Expected: PASS (hooks 4, coverage_map 6)

- [ ] **Step 5: Full suite, commit**

`bundle exec rspec` — the Task 12 fixtures haven't run yet, but the baseline integration test (`:integration`) now regenerates a v2 cache; run `OPEN_MUTATOR_INTEGRATION=1 bundle exec rspec` too. All green.
```bash
git add -A && git commit -m "feat: coverage cache v2 with primary per-example records"
```

## Task 5: AtomicFile + expanded digests

**Files:**
- Create: `lib/open_mutator/atomic_file.rb`
- Modify: `lib/open_mutator/baseline.rb`
- Test: `spec/open_mutator/atomic_file_spec.rb`, `spec/open_mutator/baseline_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/atomic_file_spec.rb`:
```ruby
require "tmpdir"

RSpec.describe OpenMutator::AtomicFile do
  it "writes content atomically" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.json")
      described_class.write(path, "{}")
      expect(File.read(path)).to eq("{}")
      expect(Dir[File.join(dir, "*.tmp*")]).to be_empty
    end
  end

  it "serializes concurrent writers via the lock file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.txt")
      pids = 4.times.map do |i|
        fork { 50.times { described_class.write(path, "writer-#{i}-" * 100) } }
      end
      pids.each { |pid| Process.waitpid(pid) }
      content = File.read(path)
      expect(content).to match(/\Awriter-\d-(writer-\d-)*\z/) # never interleaved
    end
  end
end
```

Append to `spec/open_mutator/baseline_spec.rb` (inside the describe, `:integration` inherited):
```ruby
  it "includes Gemfile.lock and .rspec in the digest set" do
    baseline = described_class.new(root: root)
    digests = baseline.send(:current_digests)
    expect(digests).to have_key("Gemfile.lock")
    expect(digests).to have_key(".rspec")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/atomic_file_spec.rb && OPEN_MUTATOR_INTEGRATION=1 bundle exec rspec spec/open_mutator/baseline_spec.rb`
Expected: FAIL (uninitialized constant; missing digest keys)

- [ ] **Step 3: Implement**

`lib/open_mutator/atomic_file.rb`:
```ruby
module OpenMutator
  # flock-guarded write-to-temp + rename. Concurrent runs in one repo (an
  # agent plus a human — the dev-loop case) must not corrupt cache or ledger.
  module AtomicFile
    def self.write(path, content)
      File.open("#{path}.lock", File::CREAT | File::RDWR, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        tmp = "#{path}.tmp#{Process.pid}"
        File.write(tmp, content)
        File.rename(tmp, path)
      end
      nil
    end
  end
end
```
Append `require_relative "open_mutator/atomic_file"` to `lib/open_mutator.rb` (before the baseline require).

In `lib/open_mutator/baseline.rb`:
- `current_digests` becomes:
```ruby
    def current_digests
      files = Dir[File.join(@root, "{app,lib,spec}/**/*.rb")].sort
      files += [File.join(@root, "Gemfile.lock"), File.join(@root, ".rspec")].select { |f| File.exist?(f) }
      files.to_h { |f| [f.delete_prefix("#{@root}/"), Digest::SHA256.file(f).hexdigest] }
    end
```
- `stamp_digests` uses AtomicFile:
```ruby
    def stamp_digests(digests)
      data = JSON.parse(File.read(@out_path))
      data["digests"] = digests
      AtomicFile.write(@out_path, JSON.generate(data))
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/atomic_file_spec.rb && OPEN_MUTATOR_INTEGRATION=1 bundle exec rspec spec/open_mutator/baseline_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: atomic flock-guarded cache writes; digest Gemfile.lock and .rspec"
```

## Task 6: BaselineDelta

**Files:**
- Create: `lib/open_mutator/baseline_delta.rb`
- Test: `spec/open_mutator/baseline_delta_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/baseline_delta_spec.rb`:
```ruby
RSpec.describe OpenMutator::BaselineDelta do
  let(:root) { "/project" }

  def coverage_map(records)
    OpenMutator::CoverageMap.new("version" => 2, "records" => records, "times" => {}, "digests" => {})
  end

  let(:records) do
    {
      "./spec/a_spec.rb[1:1]" => [["/project/lib/a.rb", 3]],
      "./spec/b_spec.rb[1:1]" => [["/project/lib/b.rb", 9]]
    }
  end

  def compute(old_d, new_d, recs: records)
    described_class.compute(old_digests: old_d, new_digests: new_d,
                            coverage_map: coverage_map(recs), root: root)
  end

  it "is empty when nothing changed" do
    d = { "lib/a.rb" => "x" }
    delta = compute(d, d)
    expect(delta.full?).to be(false)
    expect(delta.rerun_spec_files).to eq([])
    expect(delta.rerun_example_ids).to eq([])
  end

  it "re-runs a changed spec file" do
    delta = compute({ "spec/a_spec.rb" => "x" }, { "spec/a_spec.rb" => "y" })
    expect(delta.full?).to be(false)
    expect(delta.rerun_spec_files).to eq(["spec/a_spec.rb"])
  end

  it "re-runs a NEW spec file" do
    delta = compute({}, { "spec/new_spec.rb" => "y" })
    expect(delta.rerun_spec_files).to eq(["spec/new_spec.rb"])
  end

  it "re-runs examples covering a changed source file" do
    delta = compute({ "lib/a.rb" => "x" }, { "lib/a.rb" => "y" })
    expect(delta.rerun_example_ids).to eq(["./spec/a_spec.rb[1:1]"])
  end

  it "drops records for a deleted spec file that owned records" do
    delta = compute({ "spec/a_spec.rb" => "x" }, {})
    expect(delta.full?).to be(false)
    expect(delta.drop_example_ids).to eq(["./spec/a_spec.rb[1:1]"])
  end

  it "drops a deleted source file from records" do
    delta = compute({ "lib/a.rb" => "x" }, {})
    expect(delta.drop_source_files).to eq(["/project/lib/a.rb"])
  end

  it "goes full for any spec/support change" do
    expect(compute({ "spec/support/helpers.rb" => "x" }, { "spec/support/helpers.rb" => "y" }).full?).to be(true)
    expect(compute({ "spec/support/helpers.rb" => "x" }, {}).full?).to be(true)
  end

  it "goes full for a pre-existing changed spec file that owns no records (support-like)" do
    delta = compute({ "spec/shared_stuff.rb" => "x" }, { "spec/shared_stuff.rb" => "y" })
    expect(delta.full?).to be(true)
  end

  it "goes full for a deleted spec file that owned no records" do
    expect(compute({ "spec/shared_stuff.rb" => "x" }, {}).full?).to be(true)
  end

  it "goes full when non-rb keys change (Gemfile.lock, .rspec)" do
    expect(compute({ "Gemfile.lock" => "x" }, { "Gemfile.lock" => "y" }).full?).to be(true)
    expect(compute({ ".rspec" => "x" }, { ".rspec" => "y" }).full?).to be(true)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/baseline_delta_spec.rb`
Expected: FAIL — uninitialized constant

- [ ] **Step 3: Implement**

`lib/open_mutator/baseline_delta.rb`:
```ruby
module OpenMutator
  # Decides how to refresh a stale coverage cache: surgically (re-run only
  # affected spec files / examples) or fully (the safe fallback). Rules per
  # the v1.1 spec's delta table; anything ambiguous prefers full.
  class BaselineDelta
    Delta = Data.define(:full, :rerun_spec_files, :rerun_example_ids,
                        :drop_example_ids, :drop_source_files) do
      def full? = full
    end

    FULL = Delta.new(full: true, rerun_spec_files: [], rerun_example_ids: [],
                     drop_example_ids: [], drop_source_files: [])

    def self.compute(old_digests:, new_digests:, coverage_map:, root:)
      changed = (old_digests.keys | new_digests.keys)
                .reject { |k| old_digests[k] == new_digests[k] }
      return FULL if changed.any? { |k| full_trigger?(k) }

      rerun_spec_files = []
      rerun_example_ids = []
      drop_example_ids = []
      drop_source_files = []

      changed.each do |rel|
        added = !old_digests.key?(rel)
        deleted = !new_digests.key?(rel)
        if rel.start_with?("spec/")
          owned = coverage_map.examples_for_spec_file(rel)
          if deleted
            # A deleted spec file with no records is support-like: other spec
            # files may require it, and partial re-runs would explode. Full.
            return FULL if owned.empty?
            drop_example_ids.concat(owned)
          elsif !added && owned.empty?
            return FULL # pre-existing spec file owning no examples: support-like
          else
            rerun_spec_files << rel
          end
        else
          abs = File.join(root, rel)
          drop_source_files << abs if deleted
          rerun_example_ids.concat(coverage_map.examples_covering_file(abs)) unless added
        end
      end

      Delta.new(full: false,
                rerun_spec_files: rerun_spec_files.uniq.sort,
                rerun_example_ids: rerun_example_ids.uniq.sort,
                drop_example_ids: drop_example_ids.uniq.sort,
                drop_source_files: drop_source_files.uniq.sort)
    end

    def self.full_trigger?(rel)
      rel.start_with?("spec/support/") || !rel.end_with?(".rb")
    end
  end
end
```
Append `require_relative "open_mutator/baseline_delta"` to `lib/open_mutator.rb`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/baseline_delta_spec.rb`
Expected: 10 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: BaselineDelta — surgical vs full refresh decision"
```

## Task 7: Baseline delta refresh + merge

**Files:**
- Modify: `lib/open_mutator/baseline.rb`
- Create: `spec/support/fixture_copy.rb`
- Test: `spec/open_mutator/baseline_refresh_spec.rb` (`:integration`)

- [ ] **Step 1: Write the fixture-copy helper**

`spec/support/fixture_copy.rb`:
```ruby
require "fileutils"
require "tmpdir"

# Copies spec/fixtures/tiny_project into a tmpdir so tests can mutate files
# freely. The fixture's Gemfile references the gem by relative path, which
# breaks when copied — rewrite it to an absolute path. Reuses the original
# fixture's installed bundle via BUNDLE_GEMFILE at call sites.
module FixtureCopy
  GEM_ROOT = File.expand_path("../..", __dir__)
  FIXTURE = File.join(GEM_ROOT, "spec/fixtures/tiny_project")

  def with_fixture_copy
    Dir.mktmpdir do |dir|
      root = File.join(dir, "tiny_project")
      FileUtils.cp_r(FIXTURE, root)
      FileUtils.rm_rf(File.join(root, ".open_mutator"))
      gemfile = File.join(root, "Gemfile")
      File.write(gemfile, File.read(gemfile).sub('path: "../../.."', %(path: "#{GEM_ROOT}")))
      Bundler.with_unbundled_env do
        ENV["BUNDLE_GEMFILE"] = gemfile
        system("bundle", "install", "--quiet", chdir: root, out: :err) or raise "fixture bundle failed"
        yield root
      ensure
        ENV.delete("BUNDLE_GEMFILE")
      end
    end
  end
end

RSpec.configure { |c| c.include FixtureCopy }
```

- [ ] **Step 2: Write the failing integration test**

`spec/open_mutator/baseline_refresh_spec.rb`:
```ruby
require "json"

RSpec.describe "Baseline delta refresh", :integration do
  it "refreshes surgically when a spec file changes, keeping unrelated records" do
    with_fixture_copy do |root|
      baseline = OpenMutator::Baseline.new(root: root)
      map1 = baseline.coverage_map
      calculator = File.join(root, "lib/calculator.rb")
      original_examples = map1.examples_for(calculator, 3..3)
      expect(original_examples).not_to be_empty

      # Add a new spec file covering untested_helper (line 16)
      File.write(File.join(root, "spec", "helper_spec.rb"), <<~RUBY)
        RSpec.describe Calculator do
          it "covers the helper" do
            expect(Calculator.new.untested_helper).to eq(42)
          end
        end
      RUBY

      map2 = baseline.coverage_map
      expect(baseline.last_refresh).to eq(:partial)
      expect(map2.examples_for(calculator, 16..16)).not_to be_empty  # new coverage present
      expect(map2.examples_for(calculator, 3..3)).to eq(original_examples) # untouched records kept
    end
  end

  it "falls back to full re-run when a support file appears" do
    with_fixture_copy do |root|
      baseline = OpenMutator::Baseline.new(root: root)
      baseline.coverage_map
      FileUtils.mkdir_p(File.join(root, "spec", "support"))
      File.write(File.join(root, "spec", "support", "noise.rb"), "# support change\n")
      baseline.coverage_map
      expect(baseline.last_refresh).to eq(:full)
      expect(OpenMutator::CoverageMap.load(File.join(root, ".open_mutator", "coverage.json")).version).to eq(2)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `OPEN_MUTATOR_INTEGRATION=1 bundle exec rspec spec/open_mutator/baseline_refresh_spec.rb`
Expected: FAIL with `NoMethodError: undefined method 'last_refresh'` — the `last_refresh` marker (`:cached`/`:partial`/`:full`) is the observable that distinguishes surgical refresh from the always-full v1 behavior (timing assertions would be flaky).

- [ ] **Step 4: Implement**

In `lib/open_mutator/baseline.rb`, replace `coverage_map` and add the partial machinery:
```ruby
    attr_reader :last_refresh

    def coverage_map(force: false)
      digests = current_digests
      if !force && File.exist?(@out_path)
        map = CoverageMap.load(@out_path)
        if map.fresh?(digests)
          @last_refresh = :cached
          return map
        end
        if map.version == 2
          delta = BaselineDelta.compute(old_digests: stored_digests(map), new_digests: digests,
                                        coverage_map: map, root: @root)
          unless delta.full?
            run_partial!(delta)
            stamp_digests(digests)
            @last_refresh = :partial
            return CoverageMap.load(@out_path)
          end
        end
      end
      run_baseline!
      stamp_digests(digests)
      @last_refresh = :full
      CoverageMap.load(@out_path)
    end
```
and private methods:
```ruby
    def stored_digests(map)
      JSON.parse(File.read(@out_path)).fetch("digests", {})
    end

    def run_partial!(delta)
      targets = delta.rerun_spec_files + delta.rerun_example_ids
      partial_out = File.join(@cache_dir, "partial.json")
      if targets.any?
        env = baseline_env(partial_out)
        ok = system(env, "bundle", "exec", "rspec", *targets, chdir: @root, out: :err)
        raise BaselineFailed, "partial baseline run failed — fix the suite before mutating" unless ok
        raise BaselineFailed, "partial baseline produced no output" unless File.exist?(partial_out)
      end
      merge_partial!(partial_out, delta)
    ensure
      FileUtils.rm_f(partial_out) if partial_out
    end

    def merge_partial!(partial_out, delta)
      cache = JSON.parse(File.read(@out_path))
      part = File.exist?(partial_out) ? JSON.parse(File.read(partial_out)) : { "records" => {}, "times" => {} }

      rerun_prefixes = delta.rerun_spec_files.map { |rel| "#{rel}[" }
      obsolete = lambda do |example_id|
        bare = example_id.sub(%r{\A\./}, "")
        delta.rerun_example_ids.include?(example_id) ||
          delta.drop_example_ids.include?(example_id) ||
          rerun_prefixes.any? { |p| bare.start_with?(p) }
      end

      cache["records"].reject! { |id, _| obsolete.call(id) }
      cache["times"].reject! { |id, _| obsolete.call(id) }
      cache["records"].each_value do |hits|
        hits.reject! { |(path, _)| delta.drop_source_files.include?(path) }
      end
      cache["records"].merge!(part.fetch("records", {}))
      cache["times"].merge!(part.fetch("times", {}))
      AtomicFile.write(@out_path, JSON.generate(cache))
    end
```
Extract the env hash used by `run_baseline!` into `baseline_env(out_path)` and reuse it in both places:
```ruby
    def baseline_env(out_path)
      {
        "OPEN_MUTATOR" => "1",
        "OPEN_MUTATOR_ROOT" => @root,
        "OPEN_MUTATOR_BASELINE_OUT" => out_path,
        "RUBYOPT" => "-r#{File.expand_path("baseline_hooks", __dir__)}"
      }
    end
```
(`run_baseline!` keeps its raise messages; it now calls `baseline_env(@out_path)`.)
Add `require "fileutils"` if not already present (it is, from v1).

- [ ] **Step 5: Run tests to verify they pass**

Run: `OPEN_MUTATOR_INTEGRATION=1 bundle exec rspec spec/open_mutator/baseline_refresh_spec.rb spec/open_mutator/baseline_spec.rb`
Expected: PASS (refresh 2, baseline 4)

- [ ] **Step 6: Full tagged suite, commit**

Run: `OPEN_MUTATOR_INTEGRATION=1 OPEN_MUTATOR_E2E=1 bundle exec rspec` — green.
```bash
git add -A && git commit -m "feat: incremental baseline — delta refresh with record merge"
```

---

# Phase 3 — Dev-loop integration

## Task 8: SinceFilter untracked files + --changed

**Files:**
- Modify: `lib/open_mutator/since_filter.rb`, `lib/open_mutator/cli.rb`
- Test: `spec/open_mutator/since_filter_spec.rb`, `spec/open_mutator/cli_spec.rb`

- [ ] **Step 1: Write the failing tests**

Append to `spec/open_mutator/since_filter_spec.rb`:
```ruby
  describe "untracked files" do
    it "treats untracked files as fully changed (whole-file sentinel)" do
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, "lib/new.rb" => :all)

      subject_ = OpenMutator::Subject.new(name: "N#x", file: "/root/lib/new.rb",
                                          byte_range: 0...1, line_range: 500..510,
                                          constant_scope: "N", kind: :instance)
      expect(filter.cover?(subject_)).to be(true)
    end
  end
```
Append to `spec/open_mutator/cli_spec.rb` `.parse` block:
```ruby
    it "aliases --changed to --since HEAD" do
      expect(described_class.parse(%w[--changed]).since).to eq("HEAD")
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/since_filter_spec.rb spec/open_mutator/cli_spec.rb`
Expected: FAIL — `cover?` returns false for `:all`; `--changed` is an invalid option

- [ ] **Step 3: Implement**

In `lib/open_mutator/since_filter.rb`:
- `initialize` gains untracked detection after the diff parse:
```ruby
    def initialize(ref:, root:)
      @root = root
      diff = IO.popen(
        ["git", "-C", root, "diff", "--unified=0", ref, "--", "*.rb"], &:read
      )
      raise Error, "git diff #{ref} failed" unless $?.success?

      @changed = self.class.parse(diff)
      untracked = IO.popen(
        ["git", "-C", root, "ls-files", "--others", "--exclude-standard", "--", "*.rb"], &:read
      )
      # Untracked files are invisible to `git diff` but are agentic TDD's most
      # common case (brand-new file + spec). Whole-file sentinel: every line
      # counts as changed.
      untracked.each_line { |l| @changed[l.strip] = :all unless l.strip.empty? }
    end
```
- `cover?` handles the sentinel:
```ruby
    def cover?(subject)
      lines = @changed[subject.file.delete_prefix("#{@root}/")]
      return false unless lines
      return true if lines == :all

      lines.any? { |line| subject.line_range.cover?(line) }
    end
```

In `lib/open_mutator/cli.rb`, add after `--since`:
```ruby
        o.on("--changed", "Mutate uncommitted work (alias for --since HEAD, plus untracked files)") { options[:since] = "HEAD" }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/since_filter_spec.rb spec/open_mutator/cli_spec.rb`
Expected: PASS (since_filter 4, cli 7)

- [ ] **Step 5: Full suite, commit**

```bash
git add -A && git commit -m "feat: --changed flag; untracked files count as fully changed"
```

## Task 9: Fingerprint + AcceptedLedger

**Files:**
- Create: `lib/open_mutator/fingerprint.rb`, `lib/open_mutator/accepted_ledger.rb`
- Test: `spec/open_mutator/fingerprint_spec.rb`, `spec/open_mutator/accepted_ledger_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/fingerprint_spec.rb`:
```ruby
RSpec.describe OpenMutator::Fingerprint do
  def mutation(desc, snippet, range_begin, subject_name: "Calc#go", file: "/root/lib/calc.rb")
    subject_ = OpenMutator::Subject.new(name: subject_name, file: file, byte_range: 0...100,
                                        line_range: 1..10, constant_scope: "Calc", kind: :instance)
    OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: range_begin...(range_begin + 1), replacement: "x", description: desc),
      original_snippet: snippet, line: 2,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 1
    )
  end

  it "assigns ordinals to identical mutants in source order" do
    m1 = mutation("replace `>` with `>=`", ">", 10)
    m2 = mutation("replace `>` with `>=`", ">", 30)
    m3 = mutation("force condition to `true`", "a > 0", 5)
    fps = described_class.for_mutations([m2, m3, m1], root: "/root")
    expect(fps[m1].ordinal).to eq(0)   # earlier byte offset
    expect(fps[m2].ordinal).to eq(1)
    expect(fps[m3].ordinal).to eq(0)
    expect(fps[m1]).not_to eq(fps[m2]) # collision resolved
    expect(fps[m1].file).to eq("lib/calc.rb") # relative, portable
  end
end
```

`spec/open_mutator/accepted_ledger_spec.rb`:
```ruby
require "tmpdir"
require "json"

RSpec.describe OpenMutator::AcceptedLedger do
  def fp(ordinal: 0, file: "lib/calc.rb", subject: "Calc#go")
    OpenMutator::Fingerprint.new(file: file, subject: subject,
                                 description: "replace `>` with `>=`",
                                 original_snippet: ">", ordinal: ordinal)
  end

  it "loads an empty ledger when the file is absent" do
    Dir.mktmpdir do |root|
      ledger = described_class.load(root)
      expect(ledger.accepted?(fp)).to be(false)
    end
  end

  it "round-trips acceptance" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp, fp(ordinal: 1)])
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(fp)).to be(true)
      expect(reloaded.accepted?(fp(ordinal: 1))).to be(false)
      expect(File.exist?(File.join(root, ".open_mutator_accepted.json"))).to be(true)
    end
  end

  it "prunes entries that no longer match any current mutant on accept!" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp])
      # Next accept with a current set that no longer contains fp:
      described_class.load(root).accept!([fp(ordinal: 1)], [fp(ordinal: 1)])
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(fp)).to be(false)
      expect(reloaded.accepted?(fp(ordinal: 1))).to be(true)
    end
  end

  it "reports stale entries without mutating the file" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp])
      ledger = described_class.load(root)
      expect(ledger.stale_entries([fp(ordinal: 1)]).size).to eq(1)
      expect(described_class.load(root).accepted?(fp)).to be(true)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/fingerprint_spec.rb spec/open_mutator/accepted_ledger_spec.rb`
Expected: FAIL — uninitialized constants

- [ ] **Step 3: Implement**

`lib/open_mutator/fingerprint.rb`:
```ruby
module OpenMutator
  # Line-number-independent identity for a mutant, used by the acceptance
  # ledger. `ordinal` disambiguates byte-identical mutants within one subject
  # (e.g. the two `>` in `a > 0 && b > 0`) by source order — without it,
  # accepting one would silently accept both.
  Fingerprint = Data.define(:file, :subject, :description, :original_snippet, :ordinal) do
    def self.for_mutations(mutations, root:)
      counters = Hash.new(0)
      mutations.sort_by { |m| [m.subject.name, m.edit.range.begin] }.to_h do |m|
        key = [m.subject.name, m.description, m.original_snippet]
        ordinal = counters[key]
        counters[key] += 1
        [m, new(file: m.subject.file.delete_prefix("#{root}/"),
                subject: m.subject.name,
                description: m.description,
                original_snippet: m.original_snippet,
                ordinal: ordinal)]
      end
    end
  end
end
```

`lib/open_mutator/accepted_ledger.rb`:
```ruby
require "json"

module OpenMutator
  # Committed, repo-root ledger of accepted (equivalent) survivors.
  # Deliberately NOT inside .open_mutator/ — that dir is gitignored and
  # disposable, while acceptance decisions are durable team/CI state.
  class AcceptedLedger
    FILENAME = ".open_mutator_accepted.json"

    def self.load(root)
      path = File.join(root, FILENAME)
      entries = File.exist?(path) ? JSON.parse(File.read(path)) : []
      new(path, entries.map { |e| from_hash(e) })
    end

    def self.from_hash(hash)
      Fingerprint.new(file: hash.fetch("file"), subject: hash.fetch("subject"),
                      description: hash.fetch("description"),
                      original_snippet: hash.fetch("original_snippet"),
                      ordinal: hash.fetch("ordinal"))
    end

    def initialize(path, entries)
      @path = path
      @entries = entries
    end

    def accepted?(fingerprint) = @entries.include?(fingerprint)

    def stale_entries(all_current_fingerprints)
      current = all_current_fingerprints.to_set
      @entries.reject { |e| current.include?(e) }
    end

    # Union new acceptances in, prune anything no longer matching a current
    # mutant, write atomically.
    def accept!(new_fingerprints, all_current_fingerprints)
      current = all_current_fingerprints.to_set
      @entries = (@entries + new_fingerprints).uniq.select { |e| current.include?(e) }
      AtomicFile.write(@path, JSON.pretty_generate(@entries.map(&:to_h)))
      nil
    end
  end
end
```
Add `require "set"` at the top of `accepted_ledger.rb`. Append both requires to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/fingerprint"
require_relative "open_mutator/accepted_ledger"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/fingerprint_spec.rb spec/open_mutator/accepted_ledger_spec.rb`
Expected: PASS (fingerprint 1, ledger 4)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: mutant fingerprints and committed acceptance ledger"
```

## Task 10: Runner/reporter integration — accepted status, --accept-survivors, exit_reason

**Files:**
- Modify: `lib/open_mutator/runner.rb`, `lib/open_mutator/result.rb`, `lib/open_mutator/reporter/terminal.rb`, `lib/open_mutator/reporter/json.rb`
- Test: `spec/open_mutator/runner_spec.rb`, `spec/open_mutator/reporter/terminal_spec.rb`, `spec/open_mutator/reporter/json_spec.rb`

- [ ] **Step 1: Write the failing tests**

Append to `spec/open_mutator/runner_spec.rb`:
```ruby
  describe "acceptance integration" do
    it "pre-classifies ledger-accepted mutants and never schedules them" do
      m = mutation(line: 2)
      map = instance_double(OpenMutator::CoverageMap)
      allow(map).to receive(:examples_for).and_return(["e1"])
      allow(map).to receive(:time_for).and_return(0.1)
      fps = OpenMutator::Fingerprint.for_mutations([m], root: config.root)
      ledger = instance_double(OpenMutator::AcceptedLedger)
      allow(ledger).to receive(:accepted?).with(fps[m]).and_return(true)

      runner = described_class.new(config)
      items, pre_results = runner.plan_work([m], map, ledger: ledger, fingerprints: fps)
      expect(items).to eq([])
      expect(pre_results.map(&:status)).to eq([:accepted])
    end
  end
```
(Note: `plan_work`'s signature grows optional keywords; the two existing `plan_work` examples must pass `ledger: nil, fingerprints: {}` — update them accordingly, or rely on defaults: use defaults, leave them unchanged.)

In `spec/open_mutator/reporter/terminal_spec.rb`, update the progress-chars example:
```ruby
  it "prints one progress char per result" do
    %i[killed survived timeout error uncovered accepted].each { |s| reporter.on_result(result(s)) }
    expect(out.string).to eq(".STEUA")
  end
```

In `spec/open_mutator/reporter/json_spec.rb`, append inside the example after the existing expectations:
```ruby
    expect(data["exit_reason"]).to eq("unaccepted_survivors")
```
and add a second example:
```ruby
  it "reports exit_reason clean when nothing survives" do
    reporter.summary([], invalid_count: 0)
    expect(JSON.parse(out.string)["exit_reason"]).to eq("clean")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/runner_spec.rb spec/open_mutator/reporter`
Expected: FAIL (plan_work arity, missing `A` char, missing exit_reason)

- [ ] **Step 3: Implement**

`lib/open_mutator/result.rb` — update the comment only:
```ruby
  # status: :killed | :survived | :timeout | :error | :uncovered | :accepted
```

`lib/open_mutator/reporter/terminal.rb`:
- `CHARS` gains `accepted: "A"`.
- `summary` prints the ledger note: after the counts loop nothing else changes (accepted shows via CHARS iteration automatically).

`lib/open_mutator/reporter/json.rb` — in `summary`, add to the emitted hash:
```ruby
          "exit_reason" => counts.fetch(:survived, 0).positive? ? "unaccepted_survivors" : "clean",
```

`lib/open_mutator/runner.rb`:
- `#call` becomes ledger-aware (full replacement):
```ruby
    def call
      ENV["OPEN_MUTATOR"] = "1"
      preload!
      preload_spec_helper!
      map = Baseline.new(root: @config.root).coverage_map(force: @config.force_baseline)
      subjects = discover_subjects
      analyses = subjects.map { |s| Engine.new.analyze(s) }
      mutations = analyses.flat_map(&:mutations)
      invalid_count = analyses.sum(&:invalid_count)

      fingerprints = Fingerprint.for_mutations(mutations, root: @config.root)
      ledger = AcceptedLedger.load(@config.root)
      warn_stale(ledger, fingerprints.values)

      items, pre_results = plan_work(mutations, map, ledger: ledger, fingerprints: fingerprints)
      pre_results.each { |r| @reporter.on_result(r) }
      scheduler = Scheduler.new(jobs: @config.jobs, on_result: @reporter.method(:on_result))
      results = scheduler.run(items) + pre_results

      accept_survivors!(ledger, results, fingerprints) if @config.accept_survivors

      @reporter.summary(results, invalid_count: invalid_count)
      exit_code(results)
    end
```
- `plan_work` gains keywords and the accepted branch:
```ruby
    def plan_work(mutations, map, ledger: nil, fingerprints: {})
      items = []
      pre_results = []
      mutations.each do |mutation|
        if ledger&.accepted?(fingerprints[mutation])
          pre_results << Result.new(mutation: mutation, status: :accepted, details: nil)
          next
        end
        example_ids = map.examples_for(mutation.subject.file, mutation.lines)
        if example_ids.empty?
          pre_results << Result.new(mutation: mutation, status: :uncovered, details: nil)
        else
          lane = example_ids.any? { |id| serial_example?(id) } ? :serial : :parallel
          timeout = map.time_for(example_ids) * @config.timeout_factor + @config.timeout_floor
          timeout += @config.browser_boot_seconds if lane == :serial
          items << WorkItem.new(mutation: mutation, example_ids: example_ids, timeout: timeout, lane: lane)
        end
      end
      [items, pre_results]
    end
```
- New private methods:
```ruby
    def accept_survivors!(ledger, results, fingerprints)
      survivors = results.select { |r| r.status == :survived }.map { |r| fingerprints[r.mutation] }
      return if survivors.empty?

      ledger.accept!(survivors, fingerprints.values)
    end

    def warn_stale(ledger, all_fingerprints)
      ledger.stale_entries(all_fingerprints).each do |entry|
        warn "open_mutator: stale accepted fingerprint (no matching mutant): #{entry.subject} — #{entry.description}"
      end
    end
```
(`accept_survivors!` runs BEFORE summary so the run that accepts still exits 1 — acceptance takes effect on the next run; document in README. This keeps exit semantics simple and explicit.)

Note the uncovered-results rename: `#call` previously used a variable named `uncovered` — it is now `pre_results` throughout.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/runner_spec.rb spec/open_mutator/reporter spec/open_mutator/cli_spec.rb`
Expected: PASS

- [ ] **Step 5: Full suite, commit**

Run: `bundle exec rspec` — green.
```bash
git add -A && git commit -m "feat: accepted status, --accept-survivors, exit_reason"
```

---

# Phase 4 — Docs & E2E

## Task 11: mutation-check skill + README

**Files:**
- Create: `docs/skills/mutation-check.md`, `README.md`

- [ ] **Step 1: Write the skill**

`docs/skills/mutation-check.md`:
```markdown
---
name: mutation-check
description: Use after tests pass on any behavioral code change — runs scoped mutation testing to verify the new tests actually constrain the new behavior, and drives fixing every surviving mutant.
---

# Mutation Check

Green tests prove your tests pass. They do not prove your tests *constrain
the behavior you just wrote*. This skill closes that gap.

## When

After the test suite passes on any change that adds or modifies behavior
(new methods, changed logic). Skip for pure refactors with no behavior
change, docs, config.

## The loop

1. Run: `bundle exec open_mutator --changed --format json`
2. Exit 0 → done. Report the mutation counts and move on.
3. Exit 1 → read `results` where `"status": "survived"`. Each survivor is a
   concrete, machine-verified test gap: the exact source span (`file`,
   `line`, `original`, `replacement`) that can change without any test
   noticing.
4. For each survivor, write the test that kills it. The diff tells you
   exactly what behavior is unconstrained — assert on it.
5. Re-run step 1. Repeat until exit 0.

## Accepting equivalent mutants

Some mutants cannot be killed because they don't change observable behavior
(e.g. `n + 1` → `n.succ`-shaped equivalences, defensive guards provably
unreachable). Accept one ONLY with a stated equivalence argument:

- Say WHY no test can distinguish the mutant, in one sentence.
- Then: `bundle exec open_mutator --changed --accept-survivors`
- The acceptance ledger (`.open_mutator_accepted.json`, repo root) is
  committed state — include it in your commit.

Never accept a survivor because killing it is tedious. Never weaken
open_mutator flags (`--subject` scoping, patterns) to make a run pass.

## Interpreting other statuses

- `uncovered` — no example executes the mutated line at all: a missing-test
  smell stronger than a survivor. Write coverage first.
- `timeout` — counts as detected (likely an infinite-loop mutant). Fine.
- If a survivor's coverage looks implausibly thin (you KNOW a test covers
  that line), the incremental baseline may be stale in the
  newly-covering-example blind spot: re-run once with `--force-baseline`
  before writing new tests.
```

- [ ] **Step 2: Write the README**

`README.md`:
```markdown
# open_mutator

Mutation testing for Ruby, built on [Prism](https://github.com/ruby/prism).
Open source, RSpec-integrated, Rails-first.

open_mutator mutates your code one small change at a time (`>` → `>=`,
`&&` → `||`, delete a statement, force a condition…), runs exactly the
examples that cover the mutated line, and reports every mutant your suite
fails to kill. A surviving mutant is a behavior change no test notices —
a precise, machine-verified test gap.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "open_mutator"
end
```

Requires Ruby ≥ 3.2, RSpec, and a green suite. Linux/macOS (MRI fork).

## Usage

```bash
open_mutator                          # mutate app/ and lib/, full run
open_mutator app/models               # scope by path
open_mutator --changed                # uncommitted work only (dev loop)
open_mutator --since origin/main      # PR scope (CI)
open_mutator --subject 'Foo::Bar#baz' # one method
```

First run performs an instrumented baseline of your suite to build the
coverage map (cached in `.open_mutator/`, refreshed incrementally). Then
each mutant runs in its own fork against only its covering examples.

Statuses: `killed` (test failed — good), `survived` (test gap), `timeout`
(counts as detected), `uncovered` (no covering example — coverage debt),
`accepted` (known-equivalent, see ledger), `error`, `invalid` (discarded).
Exit code 1 iff unaccepted survivors exist.

Score = (killed + timeout) / (killed + timeout + survived).

## The dev loop

TDD until green, then verify the tests constrain the behavior:

```bash
bundle exec open_mutator --changed --format json
```

Kill survivors by writing the missing tests. For genuine equivalent mutants:

```bash
bundle exec open_mutator --changed --accept-survivors   # records to ledger
git add .open_mutator_accepted.json                     # committed state
```

Acceptance takes effect on the NEXT run (the accepting run still exits 1).
Agent workflow: see `docs/skills/mutation-check.md`.

## CI recipe

- Per-PR: `open_mutator --since origin/main` (minutes)
- Nightly: `open_mutator --force-baseline` (full run; also recovers the
  incremental baseline's newly-covering-example blind spot)

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--jobs N` | half the cores | fork-pool width |
| `--changed` | — | mutate uncommitted + untracked work |
| `--since REF` | — | mutate methods changed since REF |
| `--subject NAME` | — | one subject, e.g. `Foo#bar` |
| `--format terminal\|json` | terminal | report format |
| `--accept-survivors` | off | record survivors to the acceptance ledger |
| `--force-baseline` | off | ignore cached coverage map |
| `--preload-helper FILE` / `--no-preload-helper` | auto-detect | parent spec-helper preload |
| `--serial-pattern PAT` | `spec/system/`, `spec/features/` | covering-path prefixes forced serial |
| `--browser-boot-seconds S` | 15 | serial-lane timeout bump |
| `--timeout-factor F` / `--timeout-floor S` | 8 / 10 | mutation timeout budget |
| `--require FILE` | — | preload files (repeatable) |

Every open_mutator process sets `ENV["OPEN_MUTATOR"] = "1"` — use it to
guard SimpleCov or other tooling in your spec helper.

## Known limits (v1.1)

Method bodies only (no class-macro/constant mutation) · RSpec only ·
heredoc strings not mutated · `class << self` bodies and nested defs
skipped · incremental baseline can miss examples that only cover changed
code after the change (nightly `--force-baseline` recovers).
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "docs: README and mutation-check skill"
```

## Task 12: E2E — acceptance flow and --changed

**Files:**
- Test: `spec/e2e/devloop_spec.rb` (`:e2e`)
- Modify: `spec/e2e/tiny_project_spec.rb` (counts unchanged — verify only)

- [ ] **Step 1: Write the E2E**

`spec/e2e/devloop_spec.rb`:
```ruby
require "json"
require "open3"

RSpec.describe "dev-loop end-to-end", :e2e do
  def run_mutator(root, *args)
    stdout, stderr, status = Open3.capture3(
      { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
      "bundle", "exec", "open_mutator", *args, chdir: root
    )
    [stdout, stderr, status]
  end

  it "accepts survivors via the ledger and exits 0 on the next run" do
    with_fixture_copy do |root|
      out, err, status = run_mutator(root, "lib", "--format", "json")
      expect(status.exitstatus).to eq(1), err
      expect(JSON.parse(out)["counts"]["survived"]).to eq(2)

      _, err2, status2 = run_mutator(root, "lib", "--format", "json", "--accept-survivors")
      expect(status2.exitstatus).to eq(1), err2 # acceptance takes effect NEXT run
      ledger = JSON.parse(File.read(File.join(root, ".open_mutator_accepted.json")))
      expect(ledger.size).to eq(2)

      out3, err3, status3 = run_mutator(root, "lib", "--format", "json")
      data = JSON.parse(out3)
      expect(data["counts"]["accepted"]).to eq(2)
      expect(data["counts"]["survived"]).to be_nil
      expect(data["exit_reason"]).to eq("clean")
      expect(status3.exitstatus).to eq(0), err3
    end
  end

  it "scopes to uncommitted work with --changed, including untracked files" do
    with_fixture_copy do |root|
      system("git", "init", "-q", chdir: root, out: :err)
      system("git", "-C", root, "add", "-A", out: :err)
      system("git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-qm", "base", out: :err)

      # Untracked new file with a method and a spec that half-tests it
      File.write(File.join(root, "lib", "greeter.rb"), <<~RUBY)
        class Greeter
          def shout(name)
            name.to_s.upcase + "!"
          end
        end
      RUBY
      File.write(File.join(root, "spec", "greeter_spec.rb"), <<~RUBY)
        require_relative "../lib/greeter"
        RSpec.describe Greeter do
          it "shouts" do
            expect(Greeter.new.shout("hi")).to start_with("HI")
          end
        end
      RUBY

      out, err, status = run_mutator(root, "lib", "--changed", "--format", "json")
      data = JSON.parse(out)
      subjects = data["results"].map { |r| r["subject"] }.uniq
      expect(subjects).to eq(["Greeter#shout"]), err   # committed Calculator methods NOT mutated
      expect(data["results"].map { |r| r["status"] }).to include("survived") # `+ "!"` unasserted
      expect(status.exitstatus).to eq(1)
    end
  end
end
```
Note: `with_fixture_copy` requires the fixture's `spec_helper.rb` to load `lib/greeter.rb` — it doesn't; the spec file requires it itself (`require_relative`), which also makes it visible to the baseline instrumented run. The tiny_project `.rspec` (`--require spec_helper`) is untouched.

- [ ] **Step 2: Run the E2E**

Run: `OPEN_MUTATOR_E2E=1 bundle exec rspec spec/e2e/devloop_spec.rb`
Expected: PASS. Debug hints if not: acceptance test — fingerprint ordinal/relative-path mismatches show up as `accepted: 0` on run 3 (dump the ledger and compare against the JSON survivors' file/subject fields); `--changed` test — if Calculator subjects appear, `SinceFilter` ran against the wrong root or the fixture git repo didn't commit.

- [ ] **Step 3: Verify existing E2Es still hold**

Run: `OPEN_MUTATOR_INTEGRATION=1 OPEN_MUTATOR_E2E=1 bundle exec rspec`
Expected: all green — tiny_project E2E counts unchanged (2 survivors, eligible? all killed, untested_helper uncovered).

- [ ] **Step 4: Rails E2E (opt-in, heavier)**

Run: `OPEN_MUTATOR_RAILS_E2E=1 bundle exec rspec spec/e2e/rails_app_spec.rb`
Expected: PASS — the preload path now also loads the fixture app's `rails_helper` in the parent; if world-group leakage or SimpleCov assumptions break anything, this is where it shows.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "test: dev-loop E2E — acceptance ledger and --changed scoping"
```

---

## Post-plan verification (final gate)

Run: `OPEN_MUTATOR_INTEGRATION=1 OPEN_MUTATOR_E2E=1 OPEN_MUTATOR_RAILS_E2E=1 bundle exec rspec`
Expected: all green. Then a real-world smoke: rerun against payint `app/models` at new defaults and compare timeout count vs the 62/2 data points (expect ≈0–5 with the serial lane + preload).

## Out of scope (unchanged from spec)

Adaptive budget calibration · shared-browser pooling · minitest · per-method opt-out comment.
