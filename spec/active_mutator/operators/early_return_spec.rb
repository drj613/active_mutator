RSpec.describe ActiveMutator::Operators::EarlyReturn do
  subject(:operator) { described_class.new }

  def descriptions_of(source, operator)
    edits = []
    each_node(Prism.parse(source).value) { |n| edits.concat(operator.edits(n)) }
    edits.map(&:description)
  end

  it "labels each edit with an exact description" do
    expect(descriptions_of("return x", operator))
      .to contain_exactly("unwrap `return`", "return nil instead")
  end

  it "unwraps return and substitutes return nil" do
    expect(mutations_of("return x", operator))
      .to contain_exactly("x", "return nil")
  end

  it "handles modifier form" do
    expect(mutations_of("return 0 if guard?", operator))
      .to contain_exactly("0 if guard?", "return nil if guard?")
  end

  it "skips bare return" do
    expect(mutations_of("return", operator)).to eq([])
  end

  it "skips return nil (no-op)" do
    expect(mutations_of("return nil", operator)).to eq(["nil"])
  end
end
