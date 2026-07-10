require "tmpdir"

RSpec.describe OpenMutator::SubjectFinder do
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

  it "skips class << self bodies (documented v1 limit)" do
    subjects = subjects_of(<<~RUBY)
      class Widget
        class << self
          def hidden = 1
        end
        def visible = 2
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Widget#visible"])
  end

  it "records byte_range covering the whole def" do
    source = "class A\n  def b\n    1\n  end\nend\n"
    subject = subjects_of(source).first
    expect(source.byteslice(subject.byte_range)).to eq("def b\n    1\n  end")
  end

  it "returns [] for unparseable files" do
    expect(subjects_of("def broken(")).to eq([])
  end
end
