RSpec.describe ActiveMutator::Operators::ConditionalBoundary do
  subject(:operator) { described_class.new }

  it "widens and narrows comparison operators" do
    expect(mutations_of("a > b", operator)).to eq(["a >= b"])
    expect(mutations_of("a >= b", operator)).to eq(["a > b"])
    expect(mutations_of("a < b", operator)).to eq(["a <= b"])
    expect(mutations_of("a <= b", operator)).to eq(["a < b"])
  end

  it "ignores non-comparison calls" do
    expect(mutations_of("a.push(b)", operator)).to eq([])
  end

  it "ignores unary/receiverless forms" do
    expect(mutations_of("puts(1)", operator)).to eq([])
  end

  it "ignores explicit comparison calls with more than one argument" do
    expect(mutations_of("a.>(b, c)", operator)).to eq([])
  end

  it "still mutates explicit dot-form comparisons with exactly one argument" do
    expect(mutations_of("a.<(b)", operator)).to eq(["a.<=(b)"])
  end

  it "registers itself" do
    expect(ActiveMutator::Operators::Base.all.map(&:class)).to include(described_class)
  end
end
