require "fileutils"
require "tmpdir"

RSpec.describe ActiveMutator::MemoryProbe do
  let(:proc_root) { File.expand_path("../fixtures/proc", __dir__) }

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
end
