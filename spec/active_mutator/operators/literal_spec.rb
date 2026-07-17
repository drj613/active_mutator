RSpec.describe ActiveMutator::Operators::Literal do
  subject(:operator) { described_class.new }

  def descriptions_of(source, operator)
    edits = []
    each_node(Prism.parse(source).value) { |n| edits.concat(operator.edits(n)) }
    edits.map(&:description)
  end

  it "labels each edit with an exact description" do
    expect(descriptions_of("x = true", operator)).to eq(["replace `true` with `false`"])
    expect(descriptions_of("x = false", operator)).to eq(["replace `false` with `true`"])
    expect(descriptions_of(%(x = ""), operator)).to eq([%(replace "" with "active_mutator")])
    expect(descriptions_of(%(x = "hi"), operator)).to eq([%(replace string with "")])
  end

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
    expect(mutations_of(%(x = ""), operator)).to eq([%(x = "active_mutator")])
  end

  it "flips boolean literals" do
    expect(mutations_of("x = true", operator)).to eq(["x = false"])
    expect(mutations_of("x = false", operator)).to eq(["x = true"])
  end

  it "empties squiggly heredoc bodies" do
    mutants = mutations_of("x = <<~SQL\n  select 1\nSQL\n", operator)
    expect(mutants).to include("x = <<~SQL\nSQL\n")
  end

  it "empties dash heredoc bodies" do
    mutants = mutations_of("x = <<-TXT\n  hi\n  TXT\n", operator)
    expect(mutants).to include("x = <<-TXT\n  TXT\n")
  end

  it "labels heredoc body mutation" do
    descriptions = descriptions_of("x = <<~SQL\n  select 1\nSQL\n", operator)
    expect(descriptions).to include("empty heredoc body")
  end

  it "skips already-empty heredoc bodies" do
    expect(mutations_of("x = <<~SQL\nSQL\n", operator)).to eq([])
  end

  it "skips interpolated heredocs" do
    # Build the source so the interpolation is in the parsed code, not the spec.
    source = 'x = <<~SQL' + "\n" + '  #{b}' + "\nSQL\n"
    expect(mutations_of(source, operator)).to eq([])
  end

  it "skips bare string parts inside interpolation containers" do
    # Parts of "a#{b}c" are StringNodes without their own quotes; replacing
    # them with a quoted string would corrupt the container.
    mutants = mutations_of(%(x = "a\#{b}c"), operator)
    expect(mutants).to all(satisfy { |m| Prism.parse(m).success? })
  end
end
