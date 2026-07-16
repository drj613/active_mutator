RSpec.describe ActiveMutator::Operators::StatementDeletion do
  subject(:operator) { described_class.new }

  it "deletes each statement in a multi-statement body" do
    mutants = mutations_of("a\nb\nc", operator)
    expect(mutants).to contain_exactly("\nb\nc", "a\n\nc", "a\nb\n")
  end

  it "leaves single-statement bodies alone" do
    expect(mutations_of("a", operator)).to eq([])
  end

  it "deletes statements from an exactly-two-statement body" do
    expect(mutations_of("a\nb", operator)).to contain_exactly("\nb", "a\n")
  end
end
