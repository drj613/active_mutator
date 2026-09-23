require "timeout"

RSpec.describe ActiveMutator::Sampler do
  let(:samples) { [] }
  let(:bus) { ActiveMutator::Events.new.subscribe { |e| samples << e.fields if e.type == :memory } }
  let(:readings) do
    { 100 => { rss_kb: 400_000, hwm_kb: 1, pss_kb: 300_000 },
      201 => { rss_kb: 200_000, hwm_kb: 1, pss_kb: 50_000 },
      202 => { rss_kb: 210_000, hwm_kb: 1, pss_kb: nil },
      300 => { rss_kb: 900_000, hwm_kb: 1, pss_kb: 800_000 } }
  end
  let(:asked) { [] }
  let(:probe) do
    fake = Object.new
    table = readings
    log = asked
    fake.define_singleton_method(:processes) do |pids|
      log << pids
      table.slice(*pids)
    end
    fake.define_singleton_method(:system) { { mem_available_kb: 1 } }
    fake
  end
  let(:sampler) { described_class.new(events: bus, interval: 60, probe: probe, parent_pid: 100) }

  def event(type, **fields) = ActiveMutator::Events::Event.new(type: type, at: Time.now, elapsed: 0.0, fields: fields)

  it "samples the parent alone before anything else runs" do
    expect(sampler.tick).to eq(300_000)
    expect(samples.last).to eq(parent: { rss_kb: 400_000, pss_kb: 300_000 }, workers: [], baseline: nil,
                               total_pss_kb: 300_000, system: { mem_available_kb: 1 })
  end

  it "follows workers from mutant events and sums Pss, falling back to RSS" do
    sampler.call(event(:mutant_start, seq: 1, pid: 201))
    sampler.call(event(:mutant_start, seq: 2, pid: 202))
    sampler.call(event(:mutant_start, seq: 3, pid: 203)) # exited before the sample

    expect(sampler.tick).to eq(300_000 + 50_000 + 210_000)
    expect(samples.last[:workers]).to eq([{ pid: 201, seq: 1, rss_kb: 200_000, pss_kb: 50_000 },
                                          { pid: 202, seq: 2, rss_kb: 210_000, pss_kb: nil }])
    expect(asked.last).to eq([100, 201, 202, 203])

    sampler.call(event(:mutant_end, seq: 1, pid: 201))
    sampler.tick
    expect(samples.last[:workers].map { |w| w[:pid] }).to eq([202])
  end

  it "follows the baseline child for the length of its phase, sampling at each boundary" do
    sampler.call(event(:phase_start, phase: :baseline, refresh: :full, pid: 300))
    expect(samples.last[:baseline]).to eq(pid: 300, rss_kb: 900_000, pss_kb: 800_000)
    expect(samples.last[:total_pss_kb]).to eq(1_100_000)

    sampler.call(event(:phase_end, phase: :baseline))
    expect(samples.last[:baseline]).to be_nil
    expect(samples.size).to eq(2)
  end

  it "samples at other phase boundaries without touching the baseline pid" do
    sampler.call(event(:phase_start, phase: :baseline, pid: 300))
    sampler.call(event(:phase_start, phase: :coverage_load, bytes: 1))
    expect(samples.last[:baseline]).to eq(pid: 300, rss_kb: 900_000, pss_kb: 800_000)
  end

  it "ignores other events" do
    sampler.call(event(:abort, reason: :sigint))
    expect(samples).to be_empty
  end

  it "reports no total when nothing could be read" do
    readings.clear
    expect(sampler.tick).to be_nil
    expect(samples.last[:parent]).to be_nil
  end

  it "samples on its own thread every interval until stopped" do
    fast = described_class.new(events: bus, interval: 0.01, probe: probe, parent_pid: 100)
    expect(fast.start).to be(fast)
    Timeout.timeout(3) { sleep 0.01 until samples.size >= 2 }
    fast.stop
    count = samples.size
    sleep 0.05
    expect(samples.size).to eq(count)
  end

  it "waits a full interval before its first timed sample" do
    sampler.start
    sleep 0.05
    sampler.stop
    expect(samples).to be_empty
  end

  it "stops cleanly when never started" do
    expect { sampler.stop }.not_to raise_error
  end
end
