RSpec.describe OpenMutator::Operators::Literal do
  subject(:operator) { described_class.new }

  it "mutates nonzero integers to 0 and n+1" do
    expect(mutations_of("x = 5", operator)).to contain_exactly("x = 0", "x = 6")
  end

  it "mutates 0 to 1 only" do
    expect(mutations_of("x = 0", operator)).to eq(["x = 1"])
  end

  it "empties nonempty strings" do
    expect(mutations_of(%(x = "hi"), operator)).to eq([%(x = "")])
  end

  it "fills empty strings" do
    expect(mutations_of(%(x = ""), operator)).to eq([%(x = "open_mutator")])
  end

  it "flips boolean literals" do
    expect(mutations_of("x = true", operator)).to eq(["x = false"])
    expect(mutations_of("x = false", operator)).to eq(["x = true"])
  end

  it "skips heredocs" do
    expect(mutations_of("x = <<~TEXT\n  body\nTEXT\n", operator)).to eq([])
  end

  it "skips bare string parts inside interpolation containers" do
    # Parts of "a#{b}c" are StringNodes without their own quotes; replacing
    # them with a quoted string would corrupt the container.
    mutants = mutations_of(%(x = "a\#{b}c"), operator)
    expect(mutants).to all(satisfy { |m| Prism.parse(m).success? })
  end
end
