RSpec.describe ActiveMutator::Events do
  let(:ticks) { [10.0, 13.5] }
  let(:wall) { Time.utc(2026, 9, 23, 14, 2, 11) }
  let(:bus) { described_class.new(clock: -> { ticks.shift }, wall: -> { wall }) }

  it "hands listeners a frozen event stamped with wall time and seconds since the bus started" do
    seen = []
    bus.subscribe { |event| seen << event }

    bus.emit(:phase_start, phase: :baseline)

    event = seen.first
    expect([event.type, event.at, event.elapsed, event.fields]).to eq([:phase_start, wall, 3.5, { phase: :baseline }])
    expect(event).to be_frozen
    expect(event.fields).to be_frozen
  end

  it "calls every listener, in subscription order" do
    order = []
    bus.subscribe { order << :first }.subscribe(->(_) { order << :second })

    expect(bus.emit(:boot)).to be_nil
    expect(order).to eq(%i[first second])
  end

  it "is a no-op with no listeners, without even reading the clock" do
    clock = -> { raise "clock read" }
    quiet = described_class.new(clock: -> { 0.0 }, wall: clock)

    expect(quiet.emit(:boot)).to be_nil
    expect(quiet.listening?).to be(false)
  end

  it "reports whether anyone listens" do
    expect { bus.subscribe { nil } }.to change(bus, :listening?).from(false).to(true)
  end

  describe "#phase" do
    let(:ticks) { [0.0, 1.0, 2.0] }

    it "brackets the block with phase_start and phase_end and returns its value" do
      seen = []
      bus.subscribe { |e| seen << [e.type, e.fields] }

      value = bus.phase(:baseline, refresh: :full) { :done }

      expect(value).to eq(:done)
      expect(seen).to eq([[:phase_start, { phase: :baseline, refresh: :full }], [:phase_end, { phase: :baseline }]])
    end

    it "leaves the phase open when the block raises, marking where the run died" do
      seen = []
      bus.subscribe { |e| seen << e.type }

      expect { bus.phase(:baseline) { raise "boom" } }.to raise_error("boom")
      expect(seen).to eq([:phase_start])
    end
  end
end
