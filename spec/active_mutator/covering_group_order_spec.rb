require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# Real forks, a real RSpec run, and a log the specs append to, so what ran (and
# what did not) is read from the log instead of from timing. Two mutants of one
# subject share a covering set: a slow group first and, in the second file, the
# group that kills them.
RSpec.describe "Covering group order with real workers", :integration do
  # Runs in a fresh Ruby, so the outer suite's RSpec world and config stay out.
  let(:driver_source) { <<~'RUBY' }
    require "active_mutator"
    require "json"
    require "rspec/core"

    root, mode, seed = ARGV
    Dir.chdir(root)
    subject = ActiveMutator::SubjectFinder.call(File.join(root, "lib/widget.rb")).first
    mutations = ActiveMutator::Engine.new.analyze(subject).mutations.first(2)
    ids = JSON.parse(File.read(File.join(root, "ids.json")))

    # One log per mutant, so each fork's work reads on its own.
    worker = lambda do |mutation, example_ids, writer|
      ENV["AM_LOG"] = File.join(root, "log_#{mutations.index(mutation)}.txt")
      if seed != "default"
        RSpec.configuration.order = "random"
        RSpec.configuration.seed = seed.to_i
      end
      ActiveMutator::Worker.run(mutation, example_ids, writer)
    end

    items = mutations.map do |m|
      ActiveMutator::WorkItem.new(mutation: m, example_ids: ids, timeout: 60.0, lane: :parallel)
    end
    results = if mode == "learning"
                ActiveMutator::Scheduler.new(jobs: 1, worker: worker).run(items)
              else
                items.flat_map { |item| ActiveMutator::Scheduler.new(jobs: 1, worker: worker).run([item]) }
              end
    puts JSON.generate(results.map { |r| { "status" => r.status, "details" => r.details } })
  RUBY

  let(:ids) { %w[./spec/a_slow_spec.rb[1:1] ./spec/a_slow_spec.rb[2:1] ./spec/z_spec.rb[1:1] ./spec/z_spec.rb[2:1]] }

  around do |ex|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      @driver = File.join(Dir.mktmpdir, "driver.rb")
      File.write(@driver, driver_source)
      write_project
      ex.run
    ensure
      FileUtils.rm_rf(File.dirname(@driver))
    end
  end

  def write_project
    FileUtils.mkdir_p(File.join(@root, "lib"))
    FileUtils.mkdir_p(File.join(@root, "spec"))
    File.write(File.join(@root, "lib/widget.rb"), <<~RUBY)
      class Widget
        def double(x)
          x * 2
        end
      end
    RUBY
    log = ->(name) { %(File.open(ENV.fetch("AM_LOG"), "a") { |f| f.puts "#{name}" }) }
    File.write(File.join(@root, "spec/a_slow_spec.rb"), <<~RUBY)
      require_relative "../lib/widget"
      RSpec.describe "slow one" do
        it("passes") { #{log.call("slow1")}; expect(Widget).to be_a(Class) }
      end
      RSpec.describe "slow two" do
        it("passes") { #{log.call("slow2")}; expect(Widget).to be_a(Class) }
      end
    RUBY
    File.write(File.join(@root, "spec/z_spec.rb"), <<~RUBY)
      require_relative "../lib/widget"
      RSpec.describe "bystander" do
        it("passes") { #{log.call("bystander")}; expect(Widget).to be_a(Class) }
      end
      RSpec.describe "killer" do
        it("fails on a mutant") { #{log.call("killer")}; expect(Widget.new.double(3)).to eq(6) }
      end
    RUBY
    File.write(File.join(@root, "ids.json"), JSON.generate(ids))
  end

  def run_driver(mode, seed = "default")
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(FixtureCopy::GEM_ROOT, "lib"), @driver, @root, mode, seed)
    raise "driver failed (#{status.exitstatus}):\n#{err}" unless status.success?

    JSON.parse(out)
  end

  def log(index)
    path = File.join(@root, "log_#{index}.txt")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  it "makes every mutant pay for the slow groups when nothing is learned" do
    results = run_driver("fresh")

    expect(results.map { |r| r["status"] }).to eq(%w[killed killed])
    expect(log(0)).to eq(%w[slow1 slow2 bystander killer])
    expect(log(1)).to eq(%w[slow1 slow2 bystander killer])
  end

  it "skips the slow groups for the sibling of a mutant the killer group already killed" do
    results = run_driver("learning")

    expect(results.map { |r| r["status"] }).to eq(%w[killed killed]) # same verdicts as without learning
    expect(log(0)).to eq(%w[slow1 slow2 bystander killer]) # nothing learned yet: plan order
    expect(log(1)).to eq(%w[killer])                       # killer group first, run ends on its failure
  end

  [1, 7, 4242].each do |seed|
    it "keeps the ranking under random order with seed #{seed}" do
      results = run_driver("learning", seed.to_s)

      expect(results.map { |r| r["status"] }).to eq(%w[killed killed])
      expect(log(0)).to eq(%w[slow1 slow2 bystander killer])
      expect(log(1)).to eq(%w[killer])
    end
  end
end
