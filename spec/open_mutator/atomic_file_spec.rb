require "tmpdir"

RSpec.describe OpenMutator::AtomicFile do
  it "writes content atomically" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "data.json")
      described_class.write(path, "{}")
      expect(File.read(path)).to eq("{}")
      expect(Dir[File.join(dir, "*.tmp*")]).to be_empty
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
