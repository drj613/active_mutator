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

  describe "watching memory samples" do
    let(:seen) { [] }
    let(:events) { ActiveMutator::Events.new.subscribe { |e| seen << [e.type, e.fields] unless e.type == :memory } }
    let(:flag) { ActiveMutator::AbortFlag.new }
    let(:ceiling) { described_class.new(max_rss_kb: 1000, events: events, abort: flag) }

    before { events.subscribe(ceiling) }

    def sample(total) = events.emit(:memory, total_pss_kb: total)

    it "stays quiet below 90%, and on samples with no total" do
      sample(899)
      sample(nil)
      expect(seen).to eq([])
      expect(flag).not_to be_tripped
    end

    it "warns once from 90%, without stopping the run" do
      sample(900)
      sample(950)
      expect(seen).to eq([[:memory_warning, { total_pss_kb: 900, max_rss_kb: 1000 }]])
      expect(flag).not_to be_tripped
    end

    it "stops the run at 100%, once, even if more samples arrive" do
      flag.deferred do
        sample(1000)
        sample(1200)
      end
      expect(seen).to eq([[:memory_ceiling, { total_pss_kb: 1000, max_rss_kb: 1000 }]])
      expect(flag.reason).to eq(:memory_ceiling)
    end

    it "says nothing once the run is already stopping for another reason" do
      flag.deferred do
        flag.trip!(:sigterm)
        sample(1200)
      end
      expect(seen).to eq([])
      expect(flag.reason).to eq(:sigterm)
    end

    it "ignores other events" do
      events.emit(:phase_start, total_pss_kb: 5000)
      expect(flag).not_to be_tripped
    end
  end
end
