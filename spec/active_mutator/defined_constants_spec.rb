require "prism"

RSpec.describe ActiveMutator::DefinedConstants do
  it "emits only the deepest qualified name when the outer module is a pure namespace wrapper" do
    names = described_class.in_source(<<~RUBY)
      module Billing
        class Invoice
          def total; end
        end
      end
    RUBY
    expect(names).to contain_exactly("Billing::Invoice")
  end

  it "emits a namespace module that directly defines something of its own" do
    names = described_class.in_source(<<~RUBY)
      module MyApp
        def self.version = "1"

        class Config
          def flag; end
        end
      end
    RUBY
    expect(names).to contain_exactly("MyApp", "MyApp::Config")
  end

  it "treats a wrapper whose only nested definition is a module as a wrapper too" do
    names = described_class.in_source(<<~RUBY)
      module MyApp
        module Billing
          def self.rate; end
        end
      end
    RUBY
    expect(names).to contain_exactly("MyApp::Billing")
  end

  it "keeps a top-level class name as-is" do
    expect(described_class.in_source("class Invoice; end\n")).to eq(["Invoice"])
  end

  it "keeps a def-less leaf class (macro-only bodies are real edit targets)" do
    names = described_class.in_source(<<~RUBY)
      module Billing
        class Invoice
          include Comparable
        end
      end
    RUBY
    expect(names).to contain_exactly("Billing::Invoice")
  end

  it "handles compact constant paths" do
    names = described_class.in_source("class Billing::Invoice; end\n")
    expect(names).to contain_exactly("Billing::Invoice")
  end

  it "never emits the bare leaf or the wrapper namespace for a nested definition (the Config/MyApp problem)" do
    names = described_class.in_source(<<~RUBY)
      module MyApp
        class Config
          def flag; end
        end
      end
    RUBY
    expect(names).to contain_exactly("MyApp::Config")
    expect(names).not_to include("Config")
    expect(names).not_to include("MyApp")
  end

  it "returns [] when the parse has errors (truncated / mid-edit input)" do
    src = "class Oops"
    expect(Prism.parse(src).errors).not_to be_empty # pin the fixture's nature
    expect(described_class.in_source(src)).to eq([])
  end

  it "still returns names when the parse only has warnings" do
    src = <<~RUBY
      class Invoice
        def f(a)
          1 if a = 2
        end
      end
    RUBY
    result = Prism.parse(src)
    expect(result.errors).to be_empty          # pin the boundary:
    expect(result.warnings).not_to be_empty    # warnings-only input must not blank the result
    expect(described_class.in_source(src)).to eq(["Invoice"])
  end

  it "returns [] for source defining no constants" do
    expect(described_class.in_source("puts 1\n")).to eq([])
  end
end
