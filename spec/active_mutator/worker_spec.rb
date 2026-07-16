require "json"
require "stringio"

RSpec.describe ActiveMutator::Worker do
  let(:writer) { StringIO.new }
  let(:mutation) { instance_double(ActiveMutator::Mutation) }
  let(:rspec_runner) { instance_double(RSpec::Core::Runner) }

  def emitted
    JSON.parse(writer.string)
  end

  def run_worker
    described_class.new(mutation, ["spec/x_spec.rb[1:1]"], writer).run
  end

  # Every test routes through Worker#run, which sets the GLOBAL
  # RSpec.configuration.fail_fast = 1; restore it so the host suite
  # keeps its own configuration.
  around do |example|
    original = RSpec.configuration.fail_fast
    example.run
  ensure
    RSpec.configuration.fail_fast = original
  end

  before do
    allow(RSpec::Core::Runner).to receive(:new).and_return(rspec_runner)
    allow(rspec_runner).to receive(:setup)
    allow(RSpec.world).to receive(:ordered_example_groups).and_return([])
    allow_any_instance_of(ActiveMutator::Inserter).to receive(:insert)
  end

  it "emits killed when examples fail" do
    allow(rspec_runner).to receive(:run_specs).and_return(1)
    run_worker
    expect(emitted).to eq("status" => "killed", "details" => nil)
  end

  it "emits survived when examples pass" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    run_worker
    expect(emitted).to eq("status" => "survived", "details" => nil)
  end

  it "loads specs BEFORE inserting the mutation" do
    calls = []
    allow(rspec_runner).to receive(:setup) { calls << :setup }
    allow_any_instance_of(ActiveMutator::Inserter).to receive(:insert) { calls << :insert }
    allow(rspec_runner).to receive(:run_specs) do
      calls << :run_specs
      0
    end
    run_worker
    expect(calls).to eq(%i[setup insert run_specs])
  end

  it "emits error when insertion raises" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    allow_any_instance_of(ActiveMutator::Inserter)
      .to receive(:insert).and_raise(SyntaxError, "boom")
    run_worker
    expect(emitted["status"]).to eq("error")
    expect(emitted["details"]).to include("SyntaxError", "boom")
  end

  it "sets fail_fast so the first killing example ends the run" do
    fail_fast_seen = nil
    allow(rspec_runner).to receive(:run_specs) do
      fail_fast_seen = RSpec.configuration.fail_fast
      1
    end

    run_worker

    expect(fail_fast_seen).to eq(1)
  end

  it "passes the actual mutation to the inserter" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    inserted = nil
    allow_any_instance_of(ActiveMutator::Inserter).to receive(:insert) { |_, m| inserted = m }
    run_worker
    expect(inserted).to be(mutation)
  end

  it "reseeds the RNG after the fork" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    worker = described_class.new(mutation, ["spec/x_spec.rb[1:1]"], writer)
    expect(worker).to receive(:srand)
    worker.run
  end

  it "clears and reestablishes ActiveRecord connections when AR is loaded" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    handler = double("connection_handler")
    base = double("ActiveRecord::Base", connection_handler: handler)
    stub_const("ActiveRecord::Base", base)
    expect(handler).to receive(:clear_all_connections!)
    expect(base).to receive(:establish_connection)
    run_worker
  end

  it "flushes the writer when it supports flushing" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    flushing = Class.new do
      attr_reader :out, :flushed

      def initialize = (@out = +"")
      def puts(str) = @out << str << "\n"
      def flush = @flushed = true
    end.new
    described_class.new(mutation, ["spec/x_spec.rb[1:1]"], flushing).run
    expect(flushing.flushed).to be(true)
    expect(JSON.parse(flushing.out)["status"]).to eq("survived")
  end

  it "copes with writers that cannot flush" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    puts_only = Class.new do
      attr_reader :out

      def initialize = (@out = +"")
      def puts(str) = @out << str << "\n"
    end.new
    described_class.new(mutation, ["spec/x_spec.rb[1:1]"], puts_only).run
    expect(JSON.parse(puts_only.out)["status"]).to eq("survived")
  end

  it "runs only groups belonging to covering spec files (drops helper-leaked groups)" do
    covering = class_double(RSpec::Core::ExampleGroup,
                            metadata: { absolute_file_path: File.expand_path("spec/x_spec.rb") })
    leaked = class_double(RSpec::Core::ExampleGroup,
                          metadata: { absolute_file_path: File.expand_path("spec/support/leaky.rb") })
    allow(RSpec.world).to receive(:ordered_example_groups).and_return([leaked, covering])
    ran_groups = nil
    allow(rspec_runner).to receive(:run_specs) { |groups| ran_groups = groups; 0 }
    run_worker
    expect(ran_groups).to eq([covering])
  end
end
