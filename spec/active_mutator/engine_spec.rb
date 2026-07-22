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

  describe "class-body analysis" do
    def class_body_analysis(source)
      Dir.mktmpdir do |dir|
        file = File.join(dir, "user.rb")
        File.write(file, source)
        subject = ActiveMutator::SubjectFinder.call(file).find(&:class_body?)
        [ActiveMutator::Engine.new.analyze(subject, source: source), subject]
      end
    end

    # Runs the class-body subject through an engine built from a single custom
    # operator, so a test can inject one specific edit (no-op / syntax break /
    # offset shift) into the class body and observe how Engine handles it.
    def class_body_with(source, operator)
      Dir.mktmpdir do |dir|
        file = File.join(dir, "user.rb")
        File.write(file, source)
        subject = ActiveMutator::SubjectFinder.call(file).find(&:class_body?)
        ActiveMutator::Engine.new(operators: [operator]).analyze(subject, source: source)
      end
    end

    # A duck-typed operator (NOT a Base subclass, to avoid polluting REGISTRY)
    # that emits one edit for the first integer literal it sees.
    def integer_operator(replacement:, description:, range: nil)
      Class.new do
        define_method(:edits) do |node|
          next [] unless node.is_a?(Prism::IntegerNode)

          r = range || (node.location.start_offset...node.location.end_offset)
          repl = replacement == :itself ? node.slice : replacement
          [ActiveMutator::Edit.new(range: r, replacement: repl, description: description)]
        end
      end.new
    end

    it "mutates macro arguments and statements" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          validates :email, presence: true
          validates :name, length: { minimum: 2 }

          def name = "x"
        end
      RUBY
      descriptions = analysis.mutations.map { |m| m.edit.description }
      expect(descriptions).to include("replace `true` with `false`")
      expect(descriptions).to include("delete `validates :email, presence: true`")
      expect(descriptions).to include("replace `2` with `0`")
    end

    it "does not delete def statements from the class body" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 1
          Y = 2

          def name = "hello"
        end
      RUBY
      expect(analysis.mutations.map { |m| m.edit.description }).not_to include(a_string_matching(/delete `def name/))
    end

    it "does not mutate inside def bodies (owned by method subjects)" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 1
          Y = 2

          def flag = true
        end
      RUBY
      trues = analysis.mutations.select { |m| m.edit.description == "replace `true` with `false`" }
      expect(trues).to be_empty
    end

    it "mutates scope lambda bodies" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          scope :adults, -> { where("age >= 18") }
          X = 1
        end
      RUBY
      expect(analysis.mutations.map { |m| m.edit.description }).to include('replace string with ""')
    end

    it "does not mutate inside macro blocks (association extensions)" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 1
          has_many :pets do
            def flagged = true
          end
        end
      RUBY
      trues = analysis.mutations.select { |m| m.edit.description == "replace `true` with `false`" }
      expect(trues).to be_empty
    end

    it "does not mutate non-def statements inside macro blocks either" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 1
          has_many :pets do
            default_flag true
          end
        end
      RUBY
      trues = analysis.mutations.select { |m| m.edit.description == "replace `true` with `false`" }
      expect(trues).to be_empty
    end

    it "mutates statements inside an ActiveSupport::Concern `included` block" do
      analysis, = class_body_analysis(<<~RUBY)
        module Auditable
          extend ActiveSupport::Concern
          included do
            validates :name, presence: true
            AUDIT = true
          end
        end
      RUBY
      descriptions = analysis.mutations.map { |m| m.edit.description }
      expect(descriptions).to include("replace `true` with `false`")
    end

    it "mutates def bodies inside a `class_methods` block" do
      analysis, = class_body_analysis(<<~RUBY)
        module Auditable
          extend ActiveSupport::Concern
          class_methods do
            def audited? = true
          end
        end
      RUBY
      descriptions = analysis.mutations.map { |m| m.edit.description }
      expect(descriptions).to include("replace `true` with `false`")
    end

    it "does not delete defs nested in class-level control flow" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          if X
            X = 1
            def conditional = 1
          end
        end
      RUBY
      expect(analysis.mutations.map { |m| m.edit.description })
        .not_to include(a_string_matching(/delete `def conditional/))
    end

    it "does not mutate inside owned defs, classes, modules, or singleton classes" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          TOP = 1
          def a = true
          class Inner
            B = true
          end
          module Mod
            C = true
          end
          class << self
            D = true
          end
        end
      RUBY
      trues = analysis.mutations.select { |m| m.edit.description == "replace `true` with `false`" }
      expect(trues).to be_empty
    end

    it "analyzes module bodies (not just class bodies)" do
      analysis, = class_body_analysis(<<~RUBY)
        module Helpers
          TIMEOUT = 5
          def help = 1
        end
      RUBY
      expect(analysis.mutations.map { |m| m.edit.description }).to include("replace `5` with `0`")
    end

    it "anchors to the class at the subject's recorded offset among siblings" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "user.rb")
        src = <<~RUBY
          module App
            class First
              A = 1
            end
            class Second
              B = 5
            end
          end
        RUBY
        File.write(file, src)
        second = ActiveMutator::SubjectFinder.call(file).select(&:class_body?).last
        descs = ActiveMutator::Engine.new.analyze(second, source: src)
          .mutations.map { |m| m.edit.description }
        expect(descs).to include("replace `5` with `0`")     # Second's B
        expect(descs).not_to include("replace `1` with `0`") # not First's A
      end
    end

    it "raises when the class node is not found at the recorded offset" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "user.rb")
        src = "class User\n  X = 1\n  def f = 1\nend\n"
        File.write(file, src)
        subject = ActiveMutator::SubjectFinder.call(file).find(&:class_body?)
        moved = subject.with(byte_range: (subject.byte_range.begin + 1)...subject.byte_range.end)
        expect { ActiveMutator::Engine.new.analyze(moved, source: src) }
          .to raise_error(ActiveMutator::Error, "subject not found: #{moved.name}")
      end
    end

    it "reports zero invalid mutations when every class-body mutant is valid" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 5
          def f = 1
        end
      RUBY
      expect(analysis.mutations).not_to be_empty
      expect(analysis.invalid_count).to eq(0)
    end

    it "skips no-op class-body edits without counting them invalid" do
      op = integer_operator(replacement: :itself, description: "noop")
      analysis = class_body_with("class User\n  X = 1\n  def f = 1\nend\n", op)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(0)
    end

    it "counts class-body mutants that fail to re-parse as invalid" do
      op = integer_operator(replacement: "(((", description: "break syntax")
      analysis = class_body_with("class User\n  X = 1\n  def f = 1\nend\n", op)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(1)
    end

    it "counts class-body mutants that displace the class node as invalid" do
      op = integer_operator(replacement: "shift\n", description: "prepend", range: 0...0)
      analysis = class_body_with("class User\n  X = 1\n  def f = 1\nend\n", op)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(1)
    end

    it "computes the class-body mutant line from the first byte of the file" do
      analysis, = class_body_analysis("\nclass User\n  X = 5\n  def f = 1\nend\n")
      m = analysis.mutations.find { |mu| mu.edit.description == "replace `5` with `0`" }
      expect(m.line).to eq(3) # leading blank line + class line push X to line 3
    end

    it "produces whole-file mutants that still parse and keep the class node anchored" do
      analysis, subject = class_body_analysis(<<~RUBY)
        class User
          X = 5
          def name = "x"
        end
      RUBY
      m = analysis.mutations.find { |mu| mu.edit.description == "replace `5` with `0`" }
      expect(m.mutated_file_source).to include("X = 0")
      expect(m.mutated_file_source).to include('def name = "x"')
      expect(m.mutated_def_source).to eq(m.mutated_file_source)
      expect(m.mutated_def_line).to eq(1)
      expect(Prism.parse(m.mutated_file_source)).to be_success
      expect(m.subject).to eq(subject)
    end
  end
end
