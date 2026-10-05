require "json"
require "stringio"

RSpec.describe ActiveMutator::Diagnostics::Ndjson do
  let(:io) { StringIO.new }
  let(:sink) { described_class.new(io) }
  let(:at) { Time.utc(2026, 9, 23, 14, 2, 11, 123_456) }

  def emit(type, elapsed: 3.41049, **fields)
    sink.call(ActiveMutator::Events::Event.new(type: type, at: at, elapsed: elapsed, fields: fields))
  end

  it "writes one versioned object per line with a UTC millisecond timestamp" do
    emit(:phase_start, phase: :baseline)
    emit(:mutant_end, elapsed: 4.0, seq: 1, status: :killed, peak_rss_kb: nil)

    first, second = io.string.lines
    expect(first).to eq(%({"v":1,"event":"phase_start","t":"2026-09-23T14:02:11.123Z","elapsed":3.41,"phase":"baseline"}\n))
    expect(JSON.parse(second)).to eq("v" => 1, "event" => "mutant_end", "t" => "2026-09-23T14:02:11.123Z",
                                     "elapsed" => 4.0, "seq" => 1, "status" => "killed", "peak_rss_kb" => nil)
  end

  it "keeps three decimals of elapsed time" do
    emit(:boot, elapsed: 1.23456)
    expect(JSON.parse(io.string)["elapsed"]).to eq(1.235)
  end

  it "converts local times to UTC" do
    sink.call(ActiveMutator::Events::Event.new(type: :boot, at: Time.new(2026, 9, 23, 10, 0, 0, "-04:00"),
                                               elapsed: 0.0, fields: {}))
    expect(JSON.parse(io.string)["t"]).to eq("2026-09-23T14:00:00.000Z")
  end

  it "syncs the file so each line survives a kill" do
    file = instance_double(File, :sync= => true)
    described_class.new(file)
    expect(file).to have_received(:sync=).with(true)
  end
end
