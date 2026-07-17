RSpec.describe ActiveMutator::WorkItem do
  it "defaults variable and boot_extra to 0.0 so existing call sites are unchanged" do
    item = described_class.new(mutation: nil, example_ids: [], timeout: 5.0, lane: :parallel)
    expect(item.variable).to eq(0.0)
    expect(item.boot_extra).to eq(0.0)
  end

  it "accepts explicit variable and boot_extra" do
    item = described_class.new(mutation: nil, example_ids: [], timeout: 5.0, lane: :serial,
                               variable: 2.0, boot_extra: 15.0)
    expect(item.variable).to eq(2.0)
    expect(item.boot_extra).to eq(15.0)
  end
end
