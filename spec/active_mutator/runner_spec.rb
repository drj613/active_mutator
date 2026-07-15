require "tmpdir"
require "fileutils"

RSpec.describe ActiveMutator::Runner do
  let(:config) do
    ActiveMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: "/project", preload_helper: nil, serial_patterns: ["spec/system/", "spec/features/"],
      browser_boot_seconds: 15.0, accept_survivors: false, exclude: [],
      max_mutants: nil, debug_plan: false
    )
  end

  let(:subject_) do
    ActiveMutator::Subject.new(name: "A#x", file: "/project/lib/a.rb",
                             byte_range: 0...10, line_range: 1..3,
                             constant_scope: "A", kind: :instance)
  end

  def mutation(line: 2)
    ActiveMutator::Mutation.new(
      subject: subject_,
      edit: ActiveMutator::Edit.new(range: 5...6, replacement: ">=", description: "d"),
      original_snippet: ">", line: line,
      mutated_file_source: "", mutated_def_source: "def x = 1", mutated_def_line: 1
    )
  end

  it "builds work items with lanes and reports uncovered ones" do
    covered = mutation(line: 2)
    uncovered = mutation(line: 3)
    map = instance_double(ActiveMutator::CoverageMap)
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
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for)
      .and_return(["./spec/system/extractions_spec.rb[1:1]", "./spec/a_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(1.0)

    items, = described_class.new(config).plan_work([m], map)
    expect(items.first.lane).to eq(:serial)
    expect(items.first.timeout).to eq(1.0 * 4.0 + 2.0 + 15.0)
  end

  it "builds a StrykerJson reporter for :stryker_json format" do
    stryker_config = config.with(format: :stryker_json)
    reporter = described_class.new(stryker_config).instance_variable_get(:@reporter)
    expect(reporter).to be_a(ActiveMutator::Reporter::StrykerJson)
  end

  it "exits 1 when mutants survive, 0 otherwise" do
    survived = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
    killed = ActiveMutator::Result.new(mutation: mutation, status: :killed, details: nil)
    expect(described_class.new(config).exit_code([killed, survived])).to eq(1)
    expect(described_class.new(config).exit_code([killed])).to eq(0)
  end

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

  describe "#discover_subjects" do
    it "drops files matching exclude globs during discovery" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "skip.rb"), "class Skip; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated/**"]))
        subjects = runner.send(:discover_subjects)

        expect(subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "excludes nested files under a dir/** pattern" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated", "a"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "a", "deep.rb"), "class Deep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated/**"]))
        expect(runner.send(:discover_subjects).map(&:name)).to eq(["Keep#a"])
      end
    end

    it "treats a bare directory pattern as excluding everything beneath it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated", "a"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "skip.rb"), "class Skip; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "a", "deep.rb"), "class Deep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated"]))
        expect(runner.send(:discover_subjects).map(&:name)).to eq(["Keep#a"])
      end
    end

    it "supports plain file globs like **/legacy/*" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "legacy"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "legacy", "old.rb"), "class Old; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["**/legacy/*"]))
        expect(runner.send(:discover_subjects).map(&:name)).to eq(["Keep#a"])
      end
    end

    it "excludes correctly when root has a trailing slash" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "skip.rb"), "class Skip; def a; 1; end; end")

        runner = described_class.new(config.with(root: "#{dir}/", exclude: ["lib/generated"]))
        expect(runner.send(:discover_subjects).map(&:name)).to eq(["Keep#a"])
      end
    end

    it "keeps files that match no exclude pattern" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated"]))
        expect(runner.send(:discover_subjects).map(&:name)).to eq(["Keep#a"])
      end
    end

    it "applies the subject_filter expression when present" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; def b; 2; end; end")

        runner = described_class.new(config.with(root: dir, subject_filter: "Keep#a"))
        expect(runner.send(:discover_subjects).map(&:name)).to eq(["Keep#a"])
      end
    end

    it "returns all discovered subjects when subject_filter is nil" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; def b; 2; end; end")

        runner = described_class.new(config.with(root: dir, subject_filter: nil))
        expect(runner.send(:discover_subjects).map(&:name)).to contain_exactly("Keep#a", "Keep#b")
      end
    end
  end

  describe "#call" do
    def stub_call_collaborators(runner, mutations)
      allow(runner).to receive(:discover_subjects).and_return([subject_])
      analysis = ActiveMutator::Analysis.new(mutations: mutations, invalid_count: 0)
      engine = instance_double(ActiveMutator::Engine, analyze: analysis)
      allow(ActiveMutator::Engine).to receive(:new).and_return(engine)
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      allow(map).to receive(:time_for).and_return(0.1)
      baseline = instance_double(ActiveMutator::Baseline, coverage_map: map)
      allow(ActiveMutator::Baseline).to receive(:new).and_return(baseline)
    end

    it "caps mutations at max_mutants before planning" do
      Dir.mktmpdir do |dir|
        mutations = [mutation(line: 1), mutation(line: 2), mutation(line: 3)]
        cfg = config.with(root: dir, max_mutants: 2)
        reporter = instance_double(ActiveMutator::Reporter::Terminal, on_result: nil, summary: nil)
        runner = described_class.new(cfg, reporter: reporter)
        stub_call_collaborators(runner, mutations)
        scheduler = instance_double(ActiveMutator::Scheduler, run: [])
        allow(ActiveMutator::Scheduler).to receive(:new).and_return(scheduler)

        runner.call

        expect(scheduler).to have_received(:run) do |items|
          expect(items.map { |i| i.mutation.line }).to eq([1, 2])
        end
      end
    end

    it "debug_plan prints planned items as JSON and returns 0 without scheduling" do
      Dir.mktmpdir do |dir|
        mutations = [mutation(line: 1), mutation(line: 2)]
        cfg = config.with(root: dir, debug_plan: true)
        runner = described_class.new(cfg)
        stub_call_collaborators(runner, mutations)
        expect(ActiveMutator::Scheduler).not_to receive(:new)

        result = nil
        output = capture_stdout { result = runner.call }

        expect(result).to eq(0)
        parsed = JSON.parse(output)
        expect(parsed["planned"].size).to eq(2)
        item = parsed["planned"].first
        expect(item.keys).to contain_exactly("subject", "description", "file", "line", "lane", "timeout", "examples")
        expect(parsed["pre_resolved"]).to eq({})
      end
    end

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end
  end

  describe "acceptance integration" do
    it "pre-classifies ledger-accepted mutants and never schedules them" do
      m = mutation(line: 2)
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_for).and_return(["e1"])
      allow(map).to receive(:time_for).and_return(0.1)
      fps = ActiveMutator::Fingerprint.for_mutations([m], root: config.root)
      ledger = instance_double(ActiveMutator::AcceptedLedger)
      allow(ledger).to receive(:accepted?).with(fps[m]).and_return(true)

      runner = described_class.new(config)
      items, pre_results = runner.plan_work([m], map, ledger: ledger, fingerprints: fps)
      expect(items).to eq([])
      expect(pre_results.map(&:status)).to eq([:accepted])
    end
  end

  describe "#call" do
    let(:recording_reporter_class) do
      Class.new do
        attr_reader :events, :summary_results, :summary_invalid_count, :coverage_map

        def initialize
          @events = []
        end

        def coverage_map=(map)
          @coverage_map = map
        end

        def on_result(result)
          @events << result
        end

        def summary(results, invalid_count:)
          @summary_results = results
          @summary_invalid_count = invalid_count
        end
      end
    end

    let(:reporter) { recording_reporter_class.new }
    let(:map) { instance_double(ActiveMutator::CoverageMap, time_for: 0.1) }

    around do |ex|
      saved = ENV.to_h.slice("ACTIVE_MUTATOR", "RAILS_ENV")
      ENV.delete("ACTIVE_MUTATOR")
      ENV.delete("RAILS_ENV")
      Dir.mktmpdir do |root|
        @root = root
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def x\n    1 > 0\n  end\nend\n")
        FileUtils.mkdir_p(File.join(root, "spec"))
        File.write(File.join(root, "spec", "spec_helper.rb"), "$am_call_helper_loaded = true\n")
        ex.run
      end
    ensure
      ENV.delete("ACTIVE_MUTATOR")
      ENV.delete("RAILS_ENV")
      saved.each { |k, v| ENV[k] = v }
    end

    before do
      allow(ActiveMutator::Baseline)
        .to receive(:new).and_return(instance_double(ActiveMutator::Baseline, coverage_map: map))
      allow(ActiveMutator::Scheduler)
        .to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
    end

    def call_runner(**overrides)
      described_class.new(config.with(root: @root, **overrides), reporter: reporter).call
    end

    it "wires the process env, preloads, injects the coverage map and reports" do
      allow(map).to receive(:examples_for).and_return([])
      code = call_runner
      expect(ENV.fetch("ACTIVE_MUTATOR")).to eq("1")
      expect(ENV.fetch("RAILS_ENV")).to eq("test")
      expect($am_call_helper_loaded).to be(true)
      expect(reporter.coverage_map).to be(map)
      expect(reporter.events).not_to be_empty
      expect(reporter.events.map(&:status).uniq).to eq([:uncovered])
      expect(reporter.summary_results).to eq(reporter.events)
      expect(reporter.summary_invalid_count).to eq(0)
      expect(code).to eq(0)
      expect(File).not_to exist(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME))
    end

    it "returns 1 when scheduled mutants survive" do
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      survived = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
      allow(ActiveMutator::Scheduler)
        .to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: [survived]))
      expect(call_runner).to eq(1)
      expect(File).not_to exist(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME))
    end

    it "records survivors into the ledger with --accept-survivors" do
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      allow(ActiveMutator::Scheduler).to receive(:new) do |**|
        instance_double(ActiveMutator::Scheduler).tap do |s|
          allow(s).to receive(:run) do |items|
            items.map { |i| ActiveMutator::Result.new(mutation: i.mutation, status: :survived, details: nil) }
          end
        end
      end
      call_runner(accept_survivors: true)
      ledger_path = File.join(@root, ActiveMutator::AcceptedLedger::FILENAME)
      expect(File).to exist(ledger_path)
      expect(JSON.parse(File.read(ledger_path))).not_to be_empty
    end

    it "warns about stale accepted fingerprints" do
      allow(map).to receive(:examples_for).and_return([])
      stale = { "file" => "lib/gone.rb", "subject" => "Gone#away", "description" => "d",
                "original_snippet" => "x", "ordinal" => 0 }
      File.write(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME), JSON.generate([stale]))
      expect { call_runner }.to output(/stale accepted fingerprint.*Gone#away/).to_stderr
    end

    it "prints the plan and skips execution with --debug-plan" do
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      code = nil
      out = StringIO.new
      orig = $stdout
      $stdout = out
      begin
        code = call_runner(debug_plan: true)
      ensure
        $stdout = orig
      end
      expect(code).to eq(0)
      expect(ActiveMutator::Scheduler).not_to have_received(:new)
      plan = JSON.parse(out.string)
      expect(plan["planned"]).not_to be_empty
      expect(reporter.summary_results).to be_nil
    end
  end
end
