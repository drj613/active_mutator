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

  it "names the failing operator when one raises during analysis" do
    boom = Class.new(ActiveMutator::Operators::Base) do
      def self.name = "BoomOp"
      def edits(_node) = raise "kaput"
    end
    ActiveMutator::Operators::Base::REGISTRY.pop # undo self-registration
    failing = described_class.new(operators: [boom.new])
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      expect { failing.analyze(subject_) }
        .to raise_error(ActiveMutator::Error, /operator BoomOp failed .*kaput/)
    end
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

  it "counts newlines from the very first byte of the file when computing the line" do
    mutation = analyze("\n#{source}").mutations
      .find { |m| m.edit.description == "replace `>` with `>=`" }
    expect(mutation.line).to eq(4) # leading blank line pushes `>` to line 4
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

  it "mutates nested def bodies under the outer subject" do
    nested = <<~RUBY
      class Outer
        def build
          def helper; 1 + 1; end
          helper
        end
      end
    RUBY
    analysis = analyze(nested) # first subject = Outer#build
    expect(analysis.mutations.map { |m| m.edit.description })
      .to include("replace `1` with `0`")
  end

  it "raises when the source no longer parses" do
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      expect { engine.analyze(subject_, source: "def broken(") }
        .to raise_error(ActiveMutator::Error, "#{file} no longer parses")
    end
  end

  it "raises when the subject's def is not found at its recorded offset" do
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      moved = subject_.with(byte_range: (subject_.byte_range.begin + 1)...subject_.byte_range.end)
      expect { engine.analyze(moved) }
        .to raise_error(ActiveMutator::Error, "subject not found: #{moved.name}")
    end
  end

  it "locates the def by exact start offset, not just node type" do
    two_defs = <<~RUBY
      class Gate
        def first = 1 < 2
        def second(pressure) = pressure > 100
      end
    RUBY
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, two_defs)
      second = ActiveMutator::SubjectFinder.call(file).last
      analysis = engine.analyze(second)
      expect(analysis.mutations.map { |m| m.edit.description })
        .to include("replace `>` with `>=`")
      expect(analysis.mutations.map(&:mutated_def_source)).to all(start_with("def second"))
    end
  end

  it "handles defs with an empty body without yielding nil to operators" do
    strict_operator = Class.new do
      def edits(node)
        raise "operator received nil node" if node.nil?
        []
      end
    end
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, "class Gate\n  def empty; end\nend\n")
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      analysis = described_class.new(operators: [strict_operator.new]).analyze(subject_)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(0)
    end
  end

  it "skips no-op edits without counting them as invalid" do
    noop_operator = Class.new do
      def edits(node)
        return [] unless node.is_a?(Prism::IntegerNode)
        range = node.location.start_offset...node.location.end_offset
        [ActiveMutator::Edit.new(range: range, replacement: node.slice,
                                 description: "replace with itself")]
      end
    end
    engine = described_class.new(operators: [noop_operator.new])
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      analysis = engine.analyze(subject_)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(0)
    end
  end

  it "counts and discards edits that displace the subject's def" do
    # An edit inserting bytes before the def shifts its start offset, so the
    # mutated parse tree has no def at the recorded offset.
    shifting_operator = Class.new do
      def edits(node)
        return [] unless node.is_a?(Prism::IntegerNode)
        [ActiveMutator::Edit.new(range: 0...0, replacement: "# shift\n",
                                 description: "prepend comment")]
      end
    end
    engine = described_class.new(operators: [shifting_operator.new])
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = ActiveMutator::SubjectFinder.call(file).first
      analysis = engine.analyze(subject_)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(1)
    end
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
