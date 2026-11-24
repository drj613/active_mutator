require "tmpdir"
require "stringio"

RSpec.describe ActiveMutator::Runner, "incremental cache" do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "lib"))
      FileUtils.mkdir_p(File.join(@root, "spec"))
      @source = File.join(@root, "lib", "counter.rb")
      @spec = File.join(@root, "spec", "counter_spec.rb")
      File.write(@source, "class Counter\n  def count = 2\nend\n")
      File.write(@spec, "RSpec.describe(Counter) { it { expect(Counter.new.count).to eq(2) } }\n")
      Dir.chdir(@root) { example.run }
    end
  end

  before do
    allow(ActiveMutator::Baseline).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options).tap do |baseline|
        allow(baseline).to receive(:run_rspec) do |path|
          id = "./spec/counter_spec.rb[1:1]"
          File.write(path, JSON.generate("version" => 2, "records" => { id => [[@source, 2]] },
                                         "times" => { id => 0.1 }))
          true
        end
      end
    end
    allow(ActiveMutator::Worker).to receive(:run) do |_mutation, ids, writer|
      writer.puts JSON.generate("status" => "killed", "killer" => ids.first)
    end
  end

  def run_incremental(events: ActiveMutator::Events.new)
    out = StringIO.new
    reporter = ActiveMutator::Reporter::Json.new(out: out)
    config = ActiveMutator::CLI.parse(%w[--incremental --jobs 1])
    expect(config.incremental).to be(true)
    expect(described_class.new(config, events: events, reporter: reporter).call).to eq(0)
    JSON.parse(out.string)
  end

  it "carries verified verdicts on the next run without starting workers" do
    cold = run_incremental
    expect(cold.fetch("counts").fetch("killed")).to be_positive
    expect(cold.fetch("carried")).to eq(0)
    events = []
    bus = ActiveMutator::Events.new.subscribe { |event| events << event.type }
    warm = run_incremental(events: bus)

    expect(warm.fetch("counts")).to eq(cold.fetch("counts"))
    expect(warm.fetch("carried")).to eq(cold.fetch("counts").fetch("killed"))
    expect(warm.fetch("results")).to all(include("carried" => true, "seconds" => nil,
                                                 "killed_by" => ["./spec/counter_spec.rb[1:1]"]))
    expect(events).not_to include(:mutant_start)
  end

  it "does not save a verdict when execution inputs change after workers start" do
    bus = ActiveMutator::Events.new.subscribe do |event|
      File.open(@source, "a") { |file| file.puts "# changed during mutation" } if event.type == :mutant_start
    end
    run_incremental(events: bus)

    expect(File.exist?(File.join(@root, ".active_mutator", "verdicts.json"))).to be(false)
    expect(run_incremental.fetch("carried")).to eq(0)
  end
  it "leaves previous verdicts intact if a reused runner skips cache reuse" do
    source = File.read(@source)
    drift = false
    bus = ActiveMutator::Events.new.subscribe do |event|
      if drift && event.type == :phase_end && event.fields[:phase] == :planning
        File.write(@source, source + "\n# temporary edit")
      end
      if drift && event.type == :phase_start && event.fields[:phase] == :mutating
        File.write(@source, source)
      end
    end
    config = ActiveMutator::CLI.parse(%w[--incremental --jobs 1])
    runner = described_class.new(config, events: bus, reporter: ActiveMutator::Reporter::Json.new(out: StringIO.new))
    expect(runner.call).to eq(0)
    drift = true
    expect(runner.call).to eq(0)
    expect(run_incremental.fetch("carried")).to be_positive
  end
end
