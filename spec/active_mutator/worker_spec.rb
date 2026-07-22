require "json"
require "stringio"

RSpec.describe ActiveMutator::Worker do
  let(:writer) { StringIO.new }
  # Default mutation is a def mutant, routed through the Inserter.
  let(:mutation) do
    instance_double(ActiveMutator::Mutation,
                    subject: instance_double(ActiveMutator::Subject,
                                             class_body?: false, file: "/tmp/thing.rb"))
  end
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
    # Worker#run requires the subject file to guarantee the constant is
    # loaded. Stub only THAT require (the fake path can't be loaded); let
    # every other require (e.g. "rspec/core") hit the real Kernel#require so
    # mutations of those arguments still surface.
    allow_any_instance_of(described_class).to receive(:require).and_wrap_original do |orig, f|
      f == mutation.subject.file ? nil : orig.call(f)
    end
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

  it "requires the subject file, then inserts, all BEFORE loading the spec files" do
    calls = []
    allow_any_instance_of(described_class).to receive(:require) do |_, f|
      calls << :require_subject if f == mutation.subject.file
    end
    allow_any_instance_of(ActiveMutator::Inserter).to receive(:insert) { calls << :insert }
    allow(rspec_runner).to receive(:setup) { calls << :setup }
    allow(rspec_runner).to receive(:run_specs) do
      calls << :run_specs
      0
    end
    run_worker
    expect(calls).to eq(%i[require_subject insert setup run_specs])
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

  describe "class-body mutants" do
    let(:mutation) do
      subject = ActiveMutator::Subject.new(
        name: "Thing (class body)", file: "/tmp/thing.rb",
        byte_range: 0...10, line_range: 1..3,
        constant_scope: "Thing", kind: :class_body, sclass: false
      )
      ActiveMutator::Mutation.new(
        subject: subject,
        edit: ActiveMutator::Edit.new(range: 8...9, replacement: "2", description: "x", operator: "Literal"),
        original_snippet: "1", line: 2,
        mutated_file_source: "class Thing\n  X = 2\nend\n",
        mutated_def_source: "class Thing\n  X = 2\nend\n",
        mutated_def_line: 1
      )
    end

    # RSpec.describe SomeClass binds metadata[:described_class] to the constant
    # at spec-LOAD time. A class-body mutant reloads the constant to a NEW
    # object, so the reload MUST happen before setup loads the groups, or they
    # bind the pre-mutation object and falsely survive.
    it "reloads the class BEFORE loading the spec files" do
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      calls = []
      allow_any_instance_of(ActiveMutator::ClosureReload).to receive(:call) { calls << :reload }
      allow(rspec_runner).to receive(:setup) { calls << :setup }
      run_worker
      expect(calls).to eq(%i[reload setup])
    end

    it "routes class-body mutants through ClosureReload, not the Inserter" do
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      expect_any_instance_of(ActiveMutator::ClosureReload).to receive(:call)
      expect_any_instance_of(ActiveMutator::Inserter).not_to receive(:insert)
      run_worker
      expect(emitted).to eq("status" => "survived", "details" => nil)
    end

    it "reports skipped with the reason when ClosureReload raises Skip" do
      allow_any_instance_of(ActiveMutator::ClosureReload)
        .to receive(:call).and_raise(ActiveMutator::ClosureReload::Skip, "constant Thing not loaded")
      run_worker
      expect(emitted).to eq("status" => "skipped", "details" => "constant Thing not loaded")
    end

    it "reports killed when ClosureReload raises MutantLoadError (mutation broke loading)" do
      allow_any_instance_of(ActiveMutator::ClosureReload)
        .to receive(:call).and_raise(ActiveMutator::ClosureReload::MutantLoadError, "boom")
      run_worker
      expect(emitted).to eq("status" => "killed", "details" => "mutated class failed to load: boom")
    end
  end
end
