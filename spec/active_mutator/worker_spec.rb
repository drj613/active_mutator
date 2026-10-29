require "json"
require "stringio"

RSpec.describe ActiveMutator::Worker do
  let(:writer) { StringIO.new }
  # Default mutation is a def mutant, routed through the Inserter.
  let(:mutation) do
    instance_double(ActiveMutator::Mutation,
                    subject: instance_double(ActiveMutator::Subject,
                                             reload?: false, file: "/tmp/thing.rb"))
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

  it "loads the spec files BEFORE requiring the subject and inserting (def mutants)" do
    # A def mutant class_evals the live method, so it must be the last thing to
    # touch it: loading specs/app first stops a reopened-class file from
    # redefining the method back after insertion (false survivor).
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
    expect(calls).to eq(%i[setup require_subject insert run_specs])
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
    # Under self-mutation the OUTER worker's running frame has already set
    # fail_fast = 1 globally; reset so THIS call's effect is what we observe.
    RSpec.configuration.fail_fast = nil
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

  describe "covering group priority" do
    def group(file, scoped_id = nil)
      class_double(RSpec::Core::ExampleGroup,
                   metadata: { absolute_file_path: File.expand_path(file), scoped_id: scoped_id })
    end

    def worker_for(ids) = described_class.new(mutation, ids, writer)

    it "loads spec files in sorted order, whatever the run priority is" do
      loaded = nil
      allow(RSpec::Core::ConfigurationOptions).to receive(:new) { |args| loaded = args.dup }
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      worker_for(%w[spec/z_spec.rb[1:1] spec/a_spec.rb[1:1] spec/m_spec.rb[1:1]]).run
      expect(loaded).to eq(%w[spec/a_spec.rb[1:1] spec/m_spec.rb[1:1] spec/z_spec.rb[1:1]])
    end

    it "does not reorder the plan's own array while sorting the load arguments" do
      ids = %w[spec/z_spec.rb[1:1] spec/a_spec.rb[1:1]]
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      worker_for(ids).run
      expect(ids).to eq(%w[spec/z_spec.rb[1:1] spec/a_spec.rb[1:1]])
    end

    it "runs top-level groups in priority order, not load order" do
      a, b, c = group("spec/a_spec.rb", "1"), group("spec/b_spec.rb", "1"), group("spec/c_spec.rb", "1")
      allow(RSpec.world).to receive(:ordered_example_groups).and_return([a, b, c])
      ran = nil
      allow(rspec_runner).to receive(:run_specs) { |groups| ran = groups; 0 }
      worker_for(%w[spec/c_spec.rb[1:1] spec/a_spec.rb[1:1] spec/b_spec.rb[1:1]]).run
      expect(ran).to eq([c, a, b])
    end

    it "captures the selected groups before inserting a mutant of the id parser" do
      a, b = group("spec/a_spec.rb", "1"), group("spec/b_spec.rb", "1")
      allow(RSpec.world).to receive(:ordered_example_groups).and_return([a, b])
      allow_any_instance_of(ActiveMutator::Inserter).to receive(:insert) do
        allow(ActiveMutator::ExampleId).to receive(:group_key).and_return(nil)
      end
      ran = nil
      allow(rspec_runner).to receive(:run_specs) { |groups| ran = groups; 0 }

      worker_for(%w[spec/b_spec.rb[1:1] spec/a_spec.rb[1:1]]).run

      expect(ran).to eq([b, a])
    end

    it "ranks several top-level groups of one file and the nested ids inside them" do
      a1, a2, b1 = group("spec/a_spec.rb", "1"), group("spec/a_spec.rb", "2"), group("spec/b_spec.rb", "1")
      allow(RSpec.world).to receive(:ordered_example_groups).and_return([a1, a2, b1])
      ran = nil
      allow(rspec_runner).to receive(:run_specs) { |groups| ran = groups; 0 }
      worker_for(%w[./spec/a_spec.rb[2:1:3] ./spec/b_spec.rb[1:1] ./spec/a_spec.rb[1:4]]).run
      expect(ran).to eq([a2, b1, a1])
    end

    it "keeps host order for groups with equal or unknown rank" do
      known = group("spec/a_spec.rb", "1")
      other_one = group("spec/a_spec.rb", "7")
      other_two = group("spec/a_spec.rb", "8")
      allow(RSpec.world).to receive(:ordered_example_groups).and_return([other_two, other_one, known])
      ran = nil
      allow(rspec_runner).to receive(:run_specs) { |groups| ran = groups; 0 }
      worker_for(%w[spec/a_spec.rb[1:1]]).run
      expect(ran).to eq([known, other_two, other_one])
    end

    it "still drops groups leaked from a preloaded helper while ranking" do
      leaked = group("spec/support/leaky.rb", "1")
      a, b = group("spec/a_spec.rb", "1"), group("spec/b_spec.rb", "1")
      allow(RSpec.world).to receive(:ordered_example_groups).and_return([leaked, a, b])
      ran = nil
      allow(rspec_runner).to receive(:run_specs) { |groups| ran = groups; 0 }
      worker_for(%w[spec/b_spec.rb[1:1] spec/a_spec.rb[1:1]]).run
      expect(ran).to eq([b, a])
    end

    it "copes with a malformed id among the selection" do
      a = group("spec/a_spec.rb", "1")
      allow(RSpec.world).to receive(:ordered_example_groups).and_return([a])
      ran = nil
      allow(rspec_runner).to receive(:run_specs) { |groups| ran = groups; 0 }
      expect { worker_for(%w[nonsense spec/a_spec.rb[1:1]]).run }.not_to raise_error
      expect(ran).to eq([a])
    end
  end

  describe "reporting the killing example" do
    let(:reporter) { instance_double(RSpec::Core::Reporter) }
    let(:failed) { [] }

    def example(id) = instance_double(RSpec::Core::Example, id: id)

    before do
      allow(RSpec.configuration).to receive(:reporter).and_return(reporter)
      allow(reporter).to receive(:failed_examples) { failed }
    end

    def run_with(ids, code: 1, &failing)
      allow(rspec_runner).to receive(:run_specs) do
        failing&.call
        code
      end
      described_class.new(mutation, ids, writer).run
    end

    it "names the first fresh failure that is one of the selected examples" do
      run_with(%w[./spec/x_spec.rb[1:1] ./spec/y_spec.rb[1:2]]) do
        failed.push(example("./spec/y_spec.rb[1:2]"), example("./spec/x_spec.rb[1:1]"))
      end
      expect(emitted).to eq("status" => "killed", "details" => nil, "killer" => "./spec/y_spec.rb[1:2]")
    end

    it "matches the failure to a selection spelled differently" do
      run_with(%w[spec/x_spec.rb[1:1]]) { failed << example("./spec/x_spec.rb[1:1]") }
      expect(emitted["killer"]).to eq("./spec/x_spec.rb[1:1]")
    end

    it "skips failures outside the selection and reports none when nothing matches" do
      run_with(%w[./spec/x_spec.rb[1:1]]) { failed << example("./spec/leaked_spec.rb[1:1]") }
      expect(emitted).to eq("status" => "killed", "details" => nil)
    end

    it "ignores failures that were already recorded before this run" do
      failed << example("./spec/x_spec.rb[1:1]")
      run_with(%w[./spec/x_spec.rb[1:1] ./spec/x_spec.rb[1:2]]) { failed << example("./spec/x_spec.rb[1:2]") }
      expect(emitted["killer"]).to eq("./spec/x_spec.rb[1:2]")
    end

    it "reports no killer when the run failed without failed examples" do
      run_with(%w[./spec/x_spec.rb[1:1]])
      expect(emitted).to eq("status" => "killed", "details" => nil)
    end

    it "reports no killer for a survivor, even with an old failure around" do
      failed << example("./spec/x_spec.rb[1:1]")
      run_with(%w[./spec/x_spec.rb[1:1]], code: 0)
      expect(emitted).to eq("status" => "survived", "details" => nil)
    end

    it "reports no killer when the mutated class fails to load" do
      allow(rspec_runner).to receive(:setup).and_raise(ActiveMutator::ClosureReload::MutantLoadError, "boom")
      described_class.new(mutation, %w[./spec/x_spec.rb[1:1]], writer).run
      expect(emitted).to eq("status" => "killed", "details" => "mutated class failed to load: boom")
    end

    it "reports no killer for an error or a skip" do
      allow(rspec_runner).to receive(:run_specs).and_raise(StandardError, "bang")
      described_class.new(mutation, %w[./spec/x_spec.rb[1:1]], writer).run
      expect(emitted.keys).to eq(%w[status details])
      expect(emitted["status"]).to eq("error")
    end
  end

  # The mutant is inserted into the very process that is still running this
  # Worker, so a self-mutation can rewrite the code that picks the groups and
  # reports the verdict. These specs rewrite it at insertion time, like a
  # mutant would, and expect the run to finish with the original behavior.
  describe "when the mutant rewrites the worker's own code" do
    let(:reporter) { instance_double(RSpec::Core::Reporter) }
    let(:failed) { [] }
    let(:worker) { described_class.new(mutation, %w[./spec/x_spec.rb[1:1]], writer) }

    def group(file, scoped_id)
      class_double(RSpec::Core::ExampleGroup,
                   metadata: { absolute_file_path: File.expand_path(file), scoped_id: scoped_id })
    end

    def mutate_on_insert(&change)
      allow_any_instance_of(ActiveMutator::Inserter).to receive(:insert, &change)
    end

    before do
      allow(RSpec.configuration).to receive(:reporter).and_return(reporter)
      allow(reporter).to receive(:failed_examples) { failed }
    end

    it "reports with the original emit" do
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      mutate_on_insert { worker.define_singleton_method(:emit) { |*, **| raise "mutated emit" } }
      worker.run
      expect(emitted).to eq("status" => "survived", "details" => nil)
    end

    it "selects the groups with the original covering_groups" do
      x = group("spec/x_spec.rb", "1")
      allow(RSpec.world).to receive(:ordered_example_groups).and_return([x])
      ran = nil
      allow(rspec_runner).to receive(:run_specs) { |groups| ran = groups; 0 }
      mutate_on_insert { worker.define_singleton_method(:covering_groups) { [] } }
      worker.run
      expect(ran).to eq([x])
    end

    it "names the killer with the original killer" do
      allow(rspec_runner).to receive(:run_specs) do
        failed << instance_double(RSpec::Core::Example, id: "./spec/x_spec.rb[1:1]")
        1
      end
      mutate_on_insert { worker.define_singleton_method(:killer) { |_| raise "mutated killer" } }
      worker.run
      expect(emitted["killer"]).to eq("./spec/x_spec.rb[1:1]")
    end

    it "names the killer with the original id normalizer" do
      allow(rspec_runner).to receive(:run_specs) do
        failed << instance_double(RSpec::Core::Example, id: "./spec/x_spec.rb[1:1]")
        1
      end
      mutate_on_insert { allow(ActiveMutator::ExampleId).to receive(:normalize).and_raise("mutated normalize") }
      worker.run
      expect(emitted).to eq("status" => "killed", "details" => nil, "killer" => "./spec/x_spec.rb[1:1]")
    end

    it "keeps the original id parser when a reload replaces the whole ExampleId module" do
      allow(rspec_runner).to receive(:run_specs) do
        failed << instance_double(RSpec::Core::Example, id: "./spec/x_spec.rb[1:1]")
        1
      end
      mutate_on_insert { stub_const("ActiveMutator::ExampleId", Module.new) }
      worker.run
      expect(emitted).to eq("status" => "killed", "details" => nil, "killer" => "./spec/x_spec.rb[1:1]")
    end
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
    it "requires the subject file, then reloads, all BEFORE loading the spec files" do
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      calls = []
      allow_any_instance_of(described_class).to receive(:require) do |_, f|
        calls << :require_subject if f == mutation.subject.file
      end
      allow_any_instance_of(ActiveMutator::ClosureReload).to receive(:call) { calls << :reload }
      allow(rspec_runner).to receive(:setup) { calls << :setup }
      run_worker
      expect(calls).to eq(%i[require_subject reload setup])
    end

    it "routes class-body mutants through ClosureReload, not the Inserter" do
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      expect_any_instance_of(ActiveMutator::ClosureReload).to receive(:call)
      expect_any_instance_of(ActiveMutator::Inserter).not_to receive(:insert)
      run_worker
    end

    it "routes a concern `included` def (reload subject) through ClosureReload too" do
      reload_subject = mutation.subject.with(name: "Thing#label", kind: :instance, reload: true)
      allow(rspec_runner).to receive(:run_specs).and_return(0)
      expect_any_instance_of(ActiveMutator::ClosureReload).to receive(:call)
      expect_any_instance_of(ActiveMutator::Inserter).not_to receive(:insert)
      described_class.new(mutation.with(subject: reload_subject), ["spec/x_spec.rb[1:1]"], writer).run
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
