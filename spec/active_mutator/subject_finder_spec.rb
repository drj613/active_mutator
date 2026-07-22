require "tmpdir"

RSpec.describe ActiveMutator::SubjectFinder do
  def subjects_of(source)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      described_class.call(file)
    end
  end

  it "finds instance methods with constant scope" do
    subjects = subjects_of(<<~RUBY)
      module Billing
        class Calculator
          def total(items)
            items.sum
          end
        end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Billing::Calculator#total"])
    subject = subjects.first
    expect(subject.constant_scope).to eq("Billing::Calculator")
    expect(subject.kind).to eq(:instance)
    expect(subject.line_range).to eq(3..5)
  end

  it "finds singleton methods (def self.x)" do
    subjects = subjects_of(<<~RUBY)
      class Widget
        def self.build
          new
        end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Widget.build"])
    expect(subjects.first.kind).to eq(:singleton)
  end

  it "handles compact class paths and nesting" do
    subjects = subjects_of(<<~RUBY)
      class Foo::Bar
        module Baz
          def go = 1
        end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Foo::Bar::Baz#go"])
  end

  it "records top-level defs under Object" do
    subjects = subjects_of("def helper\n  1\nend\n")
    expect(subjects.map(&:name)).to eq(["Object#helper"])
    expect(subjects.first.constant_scope).to be_nil
  end

  it "treats class << self defs as singleton subjects" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        class << self
          def bar = 1
        end
        def visible = 2
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Foo.bar", "Foo#visible"])
    sclass = subjects.first
    expect(sclass.kind).to eq(:singleton)
    expect(sclass.sclass).to be(true)
    expect(sclass.constant_scope).to eq("Foo")
  end

  it "handles sibling class << self blocks independently" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        class << self
          def a = 1
        end
        class << self
          def b = 2
        end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Foo.a", "Foo.b"])
    expect(subjects.map(&:sclass)).to eq([true, true])
  end

  it "skips classes declared inside class << self (constant lives on the singleton class)" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        class << self
          class Bar
            def baz = 1
          end
        end
      end
    RUBY
    expect(subjects).to be_empty
  end

  it "skips modules declared inside class << self (constant lives on the singleton class)" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        class << self
          module Util
            def helper = 1
          end
        end
      end
    RUBY
    expect(subjects).to be_empty
  end

  it "restores the sclass context after leaving a class nested in class << self" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        class << self
          class Bar
            def baz = 1
          end
          def qux = 2
        end
      end
    RUBY
    qux = subjects.find { |s| s.name.end_with?("qux") }
    expect(qux.name).to eq("Foo.qux")
    expect(qux.sclass).to be(true)
  end

  it "pops the scope stack so sibling classes do not nest" do
    subjects = subjects_of(<<~RUBY)
      class A
        def x = 1
      end
      class B
        def y = 2
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["A#x", "B#y"])
  end

  it "does not mark def self.x as an sclass subject" do
    subject = subjects_of(<<~RUBY).first
      class Foo
        def self.bar = 1
      end
    RUBY
    expect(subject.kind).to eq(:singleton)
    expect(subject.sclass).to be(false)
  end

  it "skips class << obj (non-self) bodies" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        class << $x
          def bar = 1
        end
      end
    RUBY
    expect(subjects).to be_empty
  end

  it "skips a top-level class << self (no constant scope)" do
    subjects = subjects_of(<<~RUBY)
      class << self
        def bar = 1
      end
    RUBY
    expect(subjects).to be_empty
  end

  it "skips defs inside blocks (Data.define, class_eval) — same v1 limit" do
    subjects = subjects_of(<<~RUBY)
      module Wrap
        Point = Data.define(:x) do
          def norm = x.abs
          def self.build = new(x: 0)
        end
        def visible = 1
      end
    RUBY
    # norm/build (defined in the block) get no subject of their own; the
    # class-body subject covers Wrap's `Point = ...` constant write.
    expect(subjects.map(&:name)).to eq(["Wrap (class body)", "Wrap#visible"])
  end

  it "records byte_range covering the whole def" do
    source = "class A\n  def b\n    1\n  end\nend\n"
    subject = subjects_of(source).first
    expect(source.byteslice(subject.byte_range)).to eq("def b\n    1\n  end")
  end

  it "returns [] for unparseable files" do
    expect(subjects_of("def broken(")).to eq([])
  end

  it "skips a def annotated with active_mutator:skip on the previous line" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        # active_mutator:skip
        def skipped; 1; end

        def kept; 2; end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Foo#kept"])
  end

  it "tolerates surrounding text and whitespace in the marker" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        #   active_mutator: skip -- generated delegator
        def skipped; 1; end
      end
    RUBY
    expect(subjects).to be_empty
  end

  it "does not skip when the marker is elsewhere" do
    subjects = subjects_of(<<~RUBY)
      class Foo
        # active_mutator:skip

        def not_skipped; 1; end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Foo#not_skipped"])
  end

  describe "class-body subjects" do
    it "emits a class-body subject for a class with macro statements" do
      subjects = subjects_of(<<~RUBY)
        class User
          validates :email, presence: true

          def name = "x"
        end
      RUBY
      body = subjects.find { |s| s.kind == :class_body }
      expect(body.name).to eq("User (class body)")
      expect(body.constant_scope).to eq("User")
      expect(body.class_body?).to be(true)
      expect(body.sclass).to be(false)
      expect(body.line_range).to eq(1..5)
      expect(subjects.map(&:name)).to include("User#name")
    end

    it "emits no class-body subject for an empty class body" do
      subjects = subjects_of(<<~RUBY)
        class Empty
        end
      RUBY
      expect(subjects.select { |s| s.kind == :class_body }).to be_empty
    end

    it "emits no class-body subject when the body is only defs" do
      subjects = subjects_of(<<~RUBY)
        class User
          def name = "x"
        end
      RUBY
      expect(subjects.map(&:kind)).to eq([:instance])
    end

    it "emits class-body subjects for nested classes but not namespace wrappers" do
      subjects = subjects_of(<<~RUBY)
        module Billing
          class Calculator
            RATE = 2
          end
        end
      RUBY
      bodies = subjects.select { |s| s.kind == :class_body }
      expect(bodies.map(&:name)).to eq(["Billing::Calculator (class body)"])
    end

    it "gates on Zeitwerk shape: no class-body subjects when a file defines two top-level constants" do
      subjects = subjects_of(<<~RUBY)
        class A
          X = 1
        end
        class B
          Y = 2
        end
      RUBY
      expect(subjects.select { |s| s.kind == :class_body }).to be_empty
    end

    it "skips a class-body subject with active_mutator:skip above the class line" do
      subjects = subjects_of(<<~RUBY)
        # active_mutator:skip
        class User
          X = 1
        end
      RUBY
      expect(subjects.select { |s| s.kind == :class_body }).to be_empty
    end

    it "emits module class-body subjects" do
      subjects = subjects_of(<<~RUBY)
        module Util
          TIMEOUT = 5
          def helper = 1
        end
      RUBY
      body = subjects.find { |s| s.kind == :class_body }
      expect(body.name).to eq("Util (class body)")
    end

    it "emits no class-body subject inside class << self" do
      subjects = subjects_of(<<~RUBY)
        class Foo
          class << self
            def bar = 1
          end
        end
      RUBY
      expect(subjects.select { |s| s.kind == :class_body }).to be_empty
    end
  end
end
