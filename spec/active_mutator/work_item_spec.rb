RSpec.describe ActiveMutator::WorkItem do
  it "defaults variable to 0.0 so existing call sites are unchanged" do
    item = described_class.new(mutation: nil, example_ids: [], timeout: 5.0, lane: :parallel)
    expect(item.variable).to eq(0.0)
  end

  it "accepts an explicit variable" do
    item = described_class.new(mutation: nil, example_ids: [], timeout: 5.0, lane: :serial,
                               variable: 2.0)
    expect(item.variable).to eq(2.0)
  end
end
