RSpec.describe ActiveMutator::AbortFlag do
  let(:flag) { described_class.new }

  it "starts untripped" do
    expect(flag.tripped?).to be(false)
    expect(flag.reason).to be_nil
  end

  it "raises Aborted on the main thread at once outside a deferred block" do
    expect { flag.trip!(:sigterm) }.to raise_error(ActiveMutator::Aborted, "run aborted: sigterm") { |e|
      expect(e.reason).to eq(:sigterm)
      expect([e.results, e.in_flight]).to eq([[], []])
    }
    expect(flag.reason).to eq(:sigterm)
  end

  it "raises on the main thread when tripped from another thread" do
    expect do
      Thread.new { flag.trip!(:memory_ceiling) }.join
      sleep 1 # the raise lands here
    end.to raise_error(ActiveMutator::Aborted, /memory_ceiling/)
  end

  it "only records the reason inside a deferred block, for the owner's poll loop" do
    flag.deferred do
      flag.trip!(:sigint)
      expect(flag.tripped?).to be(true)
    end
    expect(flag.reason).to eq(:sigint)
  end

  it "keeps the first reason and ignores later trips" do
    flag.deferred { flag.trip!(:memory_ceiling) }
    expect { flag.trip!(:sigterm) }.not_to raise_error
    expect(flag.reason).to eq(:memory_ceiling)
  end

  it "raises on entering a deferred block when already tripped, without running it" do
    flag.deferred { flag.trip!(:sigint) }
    ran = false
    expect { flag.deferred { ran = true } }.to raise_error(ActiveMutator::Aborted, /sigint/)
    expect(ran).to be(false)
  end

  it "stops deferring when the block ends, even when nested" do
    flag.deferred { flag.deferred { nil } ; expect { flag.trip!(:sigint) }.not_to raise_error }
    other = described_class.new
    other.deferred { nil }
    expect { other.trip!(:sigint) }.to raise_error(ActiveMutator::Aborted)
  end
end

RSpec.describe ActiveMutator::Aborted do
  it "names the reason and swaps in new results, keeping the rest" do
    error = described_class.new(:sigterm, results: [:a], in_flight: [{ seq: 1 }])
    copy = error.with_results(%i[a b])

    expect(error.message).to eq("run aborted: sigterm")
    expect([copy.reason, copy.results, copy.in_flight]).to eq([:sigterm, %i[a b], [{ seq: 1 }]])
    expect(copy).to be_a(described_class)
  end
end
