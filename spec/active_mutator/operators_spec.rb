require "spec_helper"

RSpec.describe ActiveMutator::Operators do
  it "stamps every edit with its operator's class name" do
    node = Prism.parse("x.map { |i| i }").value.statements.body.first
    edits = ActiveMutator::Operators::CallSwap.new.edits(node)
    expect(edits).not_to be_empty
    expect(edits).to all(have_attributes(operator: "CallSwap"))
  end

  it "defaults operator to Unknown when constructed directly" do
    edit = ActiveMutator::Edit.new(range: 0...1, replacement: "y", description: "d")
    expect(edit.operator).to eq("Unknown")
  end
end
