RSpec.describe ActiveMutator::Inserter do
  subject(:inserter) { described_class.new }

  def mutation_stub(scope:, def_source:, kind: :instance)
    subject_ = ActiveMutator::Subject.new(
      name: "test", file: "(test)", byte_range: 0...1, line_range: 1..1,
      constant_scope: scope, kind: kind
    )
    instance_double(ActiveMutator::Mutation,
                    subject: subject_, mutated_def_source: def_source, mutated_def_line: 1)
  end

  before do
    stub_const("InserterFixture", Class.new do
      def value = 1
      def self.build = :original
    end)
  end

  it "redefines an instance method in the constant scope" do
    inserter.insert(mutation_stub(scope: "InserterFixture", def_source: "def value = 99"))
    expect(InserterFixture.new.value).to eq(99)
  end

  it "redefines a singleton method" do
    inserter.insert(mutation_stub(scope: "InserterFixture",
                                  def_source: "def self.build = :mutated", kind: :singleton))
    expect(InserterFixture.build).to eq(:mutated)
  end

  it "raises for unknown scopes" do
    expect { inserter.insert(mutation_stub(scope: "NoSuchScope", def_source: "def x = 1")) }
      .to raise_error(NameError)
  end
end
