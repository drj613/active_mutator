RSpec.describe ActiveMutator::Operators::StatementDeletion do
  subject(:operator) { described_class.new }

  it "deletes each statement in a multi-statement body" do
    mutants = mutations_of("a\nb\nc", operator)
    expect(mutants).to contain_exactly("\nb\nc", "a\n\nc", "a\nb\n")
  end

  it "describes multi-line statements by their first line" do
    node = Prism.parse("if a\n  b\nend\nc").value.statements
    expect(operator.edits(node).map(&:description)).to include("delete `if a`")
  end

  it "leaves single-statement bodies alone" do
    expect(mutations_of("a", operator)).to eq([])
  end

  it "deletes statements from an exactly-two-statement body" do
    expect(mutations_of("a\nb", operator)).to contain_exactly("\nb", "a\n")
  end

  it "skips statements containing a heredoc, whose body lies outside the node range" do
    source = "x = <<~MSG.chomp\n  hi\nMSG\ny = 1"
    expect(mutations_of(source, operator)).to contain_exactly("x = <<~MSG.chomp\n  hi\nMSG\n")
  end

  it "skips statements with a heredoc nested in an argument" do
    source = "foo(<<~MSG)\n  hi\nMSG\ny = 1"
    expect(mutations_of(source, operator)).to contain_exactly("foo(<<~MSG)\n  hi\nMSG\n")
  end
end
