require "spec_helper"

RSpec.describe ActiveMutator::Reporter::OperatorStats do
  def result(status, operator)
    edit = ActiveMutator::Edit.new(range: 0...1, replacement: "y", description: "d", operator: operator)
    subject = ActiveMutator::Subject.new(name: "Foo#a", file: "foo.rb", byte_range: 0...10,
                                         line_range: 1..2, constant_scope: ["Foo"], kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: "x",
                                           line: 1, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: nil)
  end

  it "aggregates counts and equivalent rate per operator" do
    results = [
      result(:killed, "CallSwap"), result(:killed, "CallSwap"), result(:survived, "CallSwap"),
      result(:killed, "Literal"),
      result(:uncovered, "Literal"), result(:accepted, "Literal"), result(:timeout, "Literal")
    ]
    stats = described_class.call(results)
    expect(stats["CallSwap"]).to eq("killed" => 2, "survived" => 1, "equivalent_rate" => 0.333)
    expect(stats["Literal"]).to eq("killed" => 1, "survived" => 0, "equivalent_rate" => 0.0)
  end

  it "rates an operator with no killed or survived mutants as 0.0" do
    stats = described_class.call([result(:uncovered, "Literal")])
    expect(stats["Literal"]).to eq("killed" => 0, "survived" => 0, "equivalent_rate" => 0.0)
  end

  it "returns an empty hash for no results" do
    expect(described_class.call([])).to eq({})
  end
end
