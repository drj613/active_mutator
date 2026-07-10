RSpec.describe ActiveMutator::Operators::LogicalOperator do
  subject(:operator) { described_class.new }

  it "swaps && with || and drops each operand" do
    expect(mutations_of("a && b", operator))
      .to contain_exactly("a || b", "a", "b")
  end

  it "swaps || with && and drops each operand" do
    expect(mutations_of("a || b", operator))
      .to contain_exactly("a && b", "a", "b")
  end

  it "handles keyword and/or (operator swap keeps symbol form)" do
    expect(mutations_of("a and b", operator)).to include("a || b", "a", "b")
  end
end
