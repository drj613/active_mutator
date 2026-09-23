require "fileutils"
require "tmpdir"

RSpec.describe ActiveMutator::MemoryProbe do
  let(:proc_root) { File.expand_path("../fixtures/proc", __dir__) }
  let(:linux) { described_class.new(proc_root: proc_root) }

  describe ".peak_rss_kb" do
    it "reads this process's VmHWM" do
      expect(described_class.peak_rss_kb(proc_root: proc_root)).to eq(831_488)
    end

    it "is nil when the status file has no VmHWM line (e.g. a zombie)" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "self"))
        File.write(File.join(root, "self/status"), "Name:\truby\nState:\tZ (zombie)\n")
        expect(described_class.peak_rss_kb(proc_root: root)).to be_nil
      end
    end

    it "is nil where /proc is missing (macOS, other platforms)" do
      expect(described_class.peak_rss_kb(proc_root: "/nonexistent")).to be_nil
    end
  end

  describe "on Linux" do
    it "reads RSS, peak, and Pss per process, skipping processes that are gone" do
      expect(linux.processes([4242, 4243, 9999])).to eq(
        4242 => { rss_kb: 1_677_722, hwm_kb: 1_703_936, pss_kb: 1_258_291 },
        4243 => { rss_kb: 204_800, hwm_kb: 262_144, pss_kb: nil } # no smaps_rollup: older kernel
      )
    end

    it "reads available memory, swap, memory pressure, and load" do
      expect(linux.system).to eq(mem_available_kb: 3_145_728, swap_total_kb: 4_194_300, swap_free_kb: 4_194_300,
                                 psi_some_avg10: 0.3, load1: 1.52)
    end

    it "leaves pressure nil where the kernel or container hides it" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "self"))
        FileUtils.cp(File.join(proc_root, "self/status"), File.join(root, "self/status"))
        FileUtils.cp(File.join(proc_root, "meminfo"), root)
        system = described_class.new(proc_root: root).system
        expect(system.values_at(:mem_available_kb, :psi_some_avg10, :load1)).to eq([3_145_728, nil, nil])
      end
    end
  end

  describe "on macOS" do
    let(:ps_calls) { [] }
    let(:mac) do
      described_class.new(proc_root: "/nonexistent", platform: "arm64-darwin24",
                          ps: lambda { |pids|
                            ps_calls << pids
                            "  4242 1677722\n 4243   204800\n"
                          })
    end

    it "reads RSS for every pid with one ps call, with no peak or Pss" do
      expect(mac.processes([4242, 4243, 9999])).to eq(
        4242 => { rss_kb: 1_677_722, hwm_kb: nil, pss_kb: nil },
        4243 => { rss_kb: 204_800, hwm_kb: nil, pss_kb: nil }
      )
      expect(ps_calls).to eq([[4242, 4243, 9999]])
    end

    it "skips ps when there is nothing to ask about" do
      expect(mac.processes([])).to eq({})
      expect(ps_calls).to be_empty
    end

    it "has no system fields" do
      expect(mac.system).to be_nil
    end

    it "asks the real ps for this process by default" do
      mine = described_class.new(proc_root: "/nonexistent", platform: "arm64-darwin24").processes([Process.pid])
      expect(mine.fetch(Process.pid)[:rss_kb]).to be > 0
    end if RUBY_PLATFORM.include?("darwin")
  end

  describe "elsewhere" do
    let(:other) do
      described_class.new(proc_root: "/nonexistent", platform: "x64-mingw-ucrt", ps: ->(_) { raise "ps called" })
    end

    it "reads nothing, and never shells out to ps" do
      expect(other.processes([4242])).to eq({})
      expect(other.system).to be_nil
    end
  end
end
