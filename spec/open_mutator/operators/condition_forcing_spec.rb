RSpec.describe ActiveMutator::Operators::ConditionForcing do
  subject(:operator) { described_class.new }

  it "forces if predicates to true and false" do
    expect(mutations_of("if a > 1\n  b\nend", operator))
      .to contain_exactly("if true\n  b\nend", "if false\n  b\nend")
  end

  it "forces unless predicates" do
    expect(mutations_of("unless ready?\n  b\nend", operator))
      .to contain_exactly("unless true\n  b\nend", "unless false\n  b\nend")
  end

  it "handles modifier ifs" do
    expect(mutations_of("b if a", operator))
      .to contain_exactly("b if true", "b if false")
  end

  it "skips predicates that are already boolean literals" do
    expect(mutations_of("if true\n  b\nend", operator)).to eq(["if false\n  b\nend"])
  end

  it "does not touch while loops" do
    expect(mutations_of("while a\n  b\nend", operator)).to eq([])
  end
end
