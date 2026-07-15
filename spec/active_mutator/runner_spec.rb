require "tmpdir"
require "fileutils"

RSpec.describe ActiveMutator::Runner do
  let(:config) do
    ActiveMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: "/project", preload_helper: nil, serial_patterns: ["spec/system/", "spec/features/"],
      browser_boot_seconds: 15.0, accept_survivors: false, exclude: []
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
end
