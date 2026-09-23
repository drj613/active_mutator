RSpec.describe ActiveMutator::MemoryCeiling do
  describe ".parse_kb" do
    it "reads G, M, and plain MB, in either case, with decimals, as kB" do
      expect(described_class.parse_kb("6G")).to eq(6_291_456)
      expect(described_class.parse_kb("1.5g")).to eq(1_572_864)
      expect(described_class.parse_kb("6144M")).to eq(6_291_456)
      expect(described_class.parse_kb("100m")).to eq(102_400)
      expect(described_class.parse_kb(" 512 ")).to eq(524_288)
      expect(described_class.parse_kb(512)).to eq(524_288)
      expect(described_class.parse_kb("0.001")).to eq(1)
    end

    it "is nil for anything that isn't a positive size" do
      ["", "0", "0G", "0.0001", "6GB", "6K", "G", "-1", "1e3", "6 G", nil, [6]].each do |bad|
        expect(described_class.parse_kb(bad)).to be_nil, bad.inspect
      end
    end
  end
end
