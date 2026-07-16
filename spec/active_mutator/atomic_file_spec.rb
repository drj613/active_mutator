require "tmpdir"

RSpec.describe ActiveMutator::AtomicFile do
  it "writes content atomically" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.json")
      described_class.write(path, "{}")
      expect(File.read(path)).to eq("{}")
      expect(Dir[File.join(dir, "*.tmp*")]).to be_empty
    end
  end

  it "returns nil rather than the rename result" do
    Dir.mktmpdir do |dir|
      expect(described_class.write(File.join(dir, "data.json"), "{}")).to be_nil
    end
  end

  it "creates the lock file with 0644 permissions" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.json")
      described_class.write(path, "{}")
      expect(File.stat("#{path}.lock").mode & 0o777).to eq(0o644)
    end
  end

  it "holds an exclusive flock on the lock file while writing" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.json")
      locked_during_write = nil
      allow(File).to receive(:write).and_wrap_original do |original, *args|
        File.open("#{path}.lock", File::CREAT | File::RDWR) do |probe|
          locked_during_write = probe.flock(File::LOCK_EX | File::LOCK_NB) == false
        end
        original.call(*args)
      end
      described_class.write(path, "{}")
      expect(locked_during_write).to be(true)
    end
  end

  it "serializes concurrent writers via the lock file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.txt")
      pids = 4.times.map do |i|
        fork { 50.times { described_class.write(path, "writer-#{i}-" * 100) } }
      end
      pids.each { |pid| Process.waitpid(pid) }
      content = File.read(path)
      expect(content).to match(/\Awriter-\d-(writer-\d-)*\z/) # never interleaved
    end
  end
end
