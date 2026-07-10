require "tmpdir"

RSpec.describe ActiveMutator::Engine do
  subject(:engine) { described_class.new }

  def analyze(source)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      engine.analyze(subject_)
    end
  end

  let(:source) do
    <<~RUBY
      class Gate
        def open?(pressure)
          pressure > 100
        end
      end
    RUBY
  end

  it "produces mutations from all applicable operators" do
    analysis = analyze(source)
    descriptions = analysis.mutations.map { |m| m.edit.description }
    expect(descriptions).to include("replace `>` with `>=`")
    expect(descriptions).to include("replace `100` with `0`")
  end

  it "captures mutated file, def source, and metadata" do
    mutation = analyze(source).mutations
      .find { |m| m.edit.description == "replace `>` with `>=`" }
    expect(mutation.mutated_file_source).to include("pressure >= 100")
    expect(mutation.mutated_def_source).to eq("def open?(pressure)\n    pressure >= 100\n  end")
    expect(mutation.mutated_def_line).to eq(2)
    expect(mutation.original_snippet).to eq(">")
    expect(mutation.line).to eq(3)
  end

  it "only mutates inside the subject's def" do
    two_methods = <<~RUBY
      class Gate
        def open?(pressure)
          pressure > 100
        end

        def other
          1 < 2
        end
      end
    RUBY
    analysis = analyze(two_methods) # first subject = open?
    expect(analysis.mutations.map(&:mutated_file_source)).to all(include("1 < 2"))
  end

  it "does not descend into nested defs" do
    nested = <<~RUBY
      class Gate
        def outer
          def inner = 1 > 0
          :ok
        end
      end
    RUBY
    analysis = analyze(nested)
    expect(analysis.mutations.map { |m| m.edit.description })
      .not_to include("replace `>` with `>=`")
  end

  it "counts and discards mutants that fail to re-parse" do
    # Deliberately NOT a subclass of Operators::Base — subclassing fires
    # `inherited` and would permanently register this syntax-breaking operator
    # in REGISTRY, poisoning Operators::Base.all for the rest of the process
    # (flaky property gate under random ordering). Engine only calls #edits,
    # so a duck type suffices.
    bad_operator = Class.new do
      def edits(node)
        return [] unless node.is_a?(Prism::IntegerNode)
        [ActiveMutator::Edit.new(range: node.location.start_offset...node.location.end_offset,
                               replacement: "(((", description: "break syntax")]
      end
    end
    engine = described_class.new(operators: [bad_operator.new])
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      analysis = engine.analyze(subject_)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(1)
    end
  end
end
