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

  describe "memory lines" do
    let(:system) do
      { mem_available_kb: 3_145_728, swap_total_kb: 4_194_300, swap_free_kb: 4_194_300, psi_some_avg10: 0.3, load1: 1.52 }
    end

    it "prints the parent, workers, baseline child, total, and system fields" do
      text = line(:memory, parent: { rss_kb: 1_677_722, pss_kb: nil },
                           workers: [{ pid: 1, seq: 3, rss_kb: 900_000, pss_kb: 524_288 },
                                     { pid: 2, seq: 4, rss_kb: 600_000, pss_kb: 524_288 }],
                           baseline: { pid: 9, rss_kb: 2_202_010, pss_kb: nil }, total_pss_kb: 4_928_308, system: system)
      expect(text).to end_with("] mem parent=1.6G workers=2:1.0G baseline=2.1G total=4.7G avail=3.0G swap=0 psi=0.3 load=1.52\n")
    end

    it "leaves out what isn't there" do
      text = line(:memory, parent: nil, workers: [], baseline: nil, total_pss_kb: nil,
                           system: { mem_available_kb: nil, swap_total_kb: nil, swap_free_kb: 1, psi_some_avg10: nil, load1: nil })
      expect(text).to end_with("] mem parent=? total=? avail=?\n")
      out.truncate(0)
      out.rewind
      expect(line(:memory, parent: nil, workers: [], baseline: nil, total_pss_kb: nil,
                           system: { mem_available_kb: 1, swap_total_kb: 1, swap_free_kb: nil }))
        .to end_with("] mem parent=? total=? avail=1K\n")
    end

    it "prints swap in use and omits the system fields off Linux" do
      expect(line(:memory, parent: { rss_kb: 2048, pss_kb: 1024 }, workers: [], baseline: nil, total_pss_kb: 1024,
                           system: system.merge(swap_free_kb: 3_145_724)))
        .to include("parent=1M total=1M avail=3.0G swap=1.0G psi")
      out.truncate(0)
      out.rewind
      expect(line(:memory, parent: { rss_kb: 2048, pss_kb: nil }, workers: [], baseline: nil, total_pss_kb: 2048, system: nil))
        .to end_with("] mem parent=2M total=2M\n")
    end
  end

  it "prints an abort with its reason and the mutants still running" do
    in_flight = [{ seq: 301, pid: 1, subject: "Foo#baz", file: "/proj/app/models/foo.rb", line: 40, description: "x" },
                 { seq: 302, pid: 2, subject: "Foo#qux", file: "/proj/app/models/foo.rb", line: 52, description: "y" }]
    expect(line(:abort, reason: :memory_ceiling, in_flight: in_flight, planned: 9, counts: {}, score: nil))
      .to end_with("] abort memory_ceiling; in flight: #301 Foo#baz app/models/foo.rb:40, #302 Foo#qux app/models/foo.rb:52\n")
    out.truncate(0)
    out.rewind
    expect(line(:abort, reason: :sigint, in_flight: [])).to end_with("] abort sigint; in flight: none\n")
  end

  it "prints the --max-rss warning and breach with the percent, the ceiling, and the total" do
    expect(line(:memory_warning, total_pss_kb: 5_767_168, max_rss_kb: 6_291_456))
      .to end_with("] warn memory at 92% of --max-rss 6.0G (5.5G)\n")
    out.truncate(0)
    out.rewind
    expect(line(:memory_ceiling, total_pss_kb: 6_396_314, max_rss_kb: 6_291_456))
      .to end_with("] memory at 102% of --max-rss 6.0G (6.1G); stopping the run\n")
  end

  it "says when the total is an estimate for reading coverage.json" do
    expect(line(:memory_ceiling, total_pss_kb: 9_437_184, max_rss_kb: 6_291_456, coverage_bytes: 1_825_361_101))
      .to end_with("] memory at 150% of --max-rss 6.0G (9.0G estimated to read a 1.7G coverage.json); " \
                   "stopping the run\n")
    out.truncate(0)
    out.rewind
    expect(line(:memory_warning, total_pss_kb: 900, max_rss_kb: 1000, coverage_bytes: 1_024_000))
      .to end_with("(900K estimated to read a 1000K coverage.json)\n")
  end

  it "prints only the listed event types when given `only`" do
    only = described_class.new(root: "/proj/", out: out, only: [:memory_warning])
    only.call(ActiveMutator::Events::Event.new(type: :phase_start, at: at, elapsed: 1.0, fields: { phase: :boot }))
    expect(out.string).to eq("")
    only.call(ActiveMutator::Events::Event.new(type: :memory_warning, at: at, elapsed: 1.0,
                                               fields: { total_pss_kb: 900, max_rss_kb: 1000 }))
    expect(out.string).to end_with("] warn memory at 90% of --max-rss 1000K (900K)\n")
  end

  it "prints other events as key=value pairs" do
    expect(line(:tick, reason: :sigterm, n: 2)).to end_with("] tick reason=sigterm n=2\n")
  end

  describe ".size_kb" do
    it "scales to K, M, and G, and shows ? for a missing reading" do
      sizes = [nil, 0, 1023, 1024, 831_488, 1_048_575, 1_048_576, 1_677_722].map { |kb| ActiveMutator::Diagnostics.size_kb(kb) }
      expect(sizes).to eq(["?", "0", "1023K", "1M", "812M", "1024M", "1.0G", "1.6G"])
    end
  end
end
