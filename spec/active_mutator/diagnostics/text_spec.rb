require "stringio"

RSpec.describe ActiveMutator::Diagnostics::Text do
  let(:out) { StringIO.new }
  let(:sink) { described_class.new(root: "/proj/", out: out) }
  let(:at) { Time.new(2026, 9, 23, 14, 2, 11) }

  def line(type, elapsed: 3.44, **fields)
    sink.call(ActiveMutator::Events::Event.new(type: type, at: at, elapsed: elapsed, fields: fields))
    out.string
  end

  it "stamps each line with the wall clock and seconds since boot" do
    expect(line(:phase_start, phase: :baseline)).to eq("[active_mutator 14:02:11 +3.4s] phase baseline start\n")
  end

  it "prints phase ends and extra phase fields, sizing bytes" do
    expect(line(:phase_end, phase: :coverage_load, examples: 3362))
      .to eq("[active_mutator 14:02:11 +3.4s] phase coverage_load end examples=3362\n")
    out.truncate(0)
    out.rewind
    expect(line(:phase_start, phase: :coverage_load, bytes: 2_202_009_600))
      .to end_with("phase coverage_load start size=2.1G\n")
  end

  it "prints a mutant start with its pid, lane, subject, root-relative location, and description" do
    text = line(:mutant_start, seq: 12, pid: 4242, lane: :parallel, budget: 12.0, examples: 3, subject: "Foo#bar",
                               file: "/proj/app/models/foo.rb", line: 10, description: "replace > with >=")
    expect(text).to end_with("] mutant start #12 pid=4242 parallel Foo#bar app/models/foo.rb:10 replace > with >=\n")
  end

  it "prints a mutant end with its status, time, and peak" do
    text = line(:mutant_end, seq: 12, pid: 4242, status: :killed, seconds: 1.84, peak_rss_kb: 831_488)
    expect(text).to end_with("] mutant end #12 killed 1.8s peak=812M\n")
  end

  it "prints other events as key=value pairs" do
    expect(line(:abort, reason: :sigterm)).to end_with("] abort reason=sigterm\n")
  end

  describe ".size_kb" do
    it "scales to K, M, and G, and shows ? for a missing reading" do
      sizes = [nil, 0, 1023, 1024, 831_488, 1_048_575, 1_048_576, 1_677_722].map { |kb| ActiveMutator::Diagnostics.size_kb(kb) }
      expect(sizes).to eq(["?", "0K", "1023K", "1M", "812M", "1024M", "1.0G", "1.6G"])
    end
  end
end
