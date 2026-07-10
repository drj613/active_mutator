RSpec.describe OpenMutator::Operators::NegationRemoval do
  subject(:operator) { described_class.new }

  it "removes unary bang" do
    expect(mutations_of("!ready?", operator)).to eq(["ready?"])
  end

  it "removes bang from parenthesized expressions" do
    expect(mutations_of("!(a && b)", operator)).to eq(["(a && b)"])
  end

  it "ignores binary operators" do
    expect(mutations_of("a != b", operator)).to eq([])
  end
end
