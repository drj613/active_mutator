require "fileutils"
require "json"
require "tmpdir"

# The parent reads coverage.json back after the child writes it. On a big
# suite that file is huge, and each extra parse is another copy of it in
# memory (0.6.0 parsed it three times and got the runner killed). Every
# refresh path must read the cache exactly once.
RSpec.describe ActiveMutator::Baseline do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "lib"))
      FileUtils.mkdir_p(File.join(@root, "spec"))
      File.write(File.join(@root, "lib/a.rb"), "class A; def x = 1; end\n")
      File.write(File.join(@root, "spec/a_spec.rb"), "RSpec.describe(A) { it { A.new.x } }\n")
      example.run
    end
  end

  let(:cache_dir) { File.join(@root, ".active_mutator") }
  let(:out_path) { File.join(cache_dir, "coverage.json") }
  let(:baseline) { described_class.new(root: @root, cache_dir: cache_dir) }
  let(:a_hit) { [[File.join(@root, "lib/a.rb"), 1]] }

  # A stand-in for the child: writes a payload where the real hooks would.
  def fake_child(records)
    allow(baseline).to receive(:run_rspec) do |path, _targets = []|
      File.write(path, JSON.generate("version" => 2, "records" => records, "times" => {},
                                     "expected_examples" => records.size))
      true
    end
  end

  def write_cache(digests)
    FileUtils.mkdir_p(cache_dir)
    File.write(out_path, JSON.generate("version" => 2, "records" => { "./spec/a_spec.rb[1:1]" => a_hit },
                                       "times" => {}, "digests" => digests, "spec_paths" => ["spec"]))
  end

  def cache_reads
    reads = 0
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(out_path).and_wrap_original do |original, *args|
      reads += 1
      original.call(*args)
    end
    yield
    reads
  end

  it "reads a fresh cache once" do
    write_cache(baseline.send(:current_digests))

    expect(cache_reads { baseline.coverage_map }).to eq(1)
    expect(baseline.last_refresh).to eq(:cached)
  end

  it "reads the cache once on a partial refresh and keeps the merged records" do
    digests = baseline.send(:current_digests)
    write_cache(digests)
    File.write(File.join(@root, "spec/b_spec.rb"), "RSpec.describe(A) { it { A.new.x } }\n")
    fake_child("./spec/b_spec.rb[1:1]" => a_hit)

    map = nil
    expect(cache_reads { map = baseline.coverage_map }).to eq(1)
    expect(baseline.last_refresh).to eq(:partial)
    expect(map.examples_for(File.join(@root, "lib/a.rb"), [1]))
      .to eq(["./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]"])
    expect(JSON.parse(File.read(out_path))["records"].keys).to eq(["./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]"])
    expect(JSON.parse(File.read(out_path))["digests"]).to eq(baseline.send(:current_digests))
  end

  it "reads the new file once on a full rebuild with no cache" do
    fake_child("./spec/a_spec.rb[1:1]" => a_hit)

    map = nil
    expect(cache_reads { map = baseline.coverage_map }).to eq(1)
    expect(baseline.last_refresh).to eq(:full)
    expect(map.examples_for(File.join(@root, "lib/a.rb"), [1])).to eq(["./spec/a_spec.rb[1:1]"])
    stamped = JSON.parse(File.read(out_path))
    expect(stamped.values_at("digests", "spec_paths")).to eq([baseline.send(:current_digests), ["spec"]])
  end

  it "reads the stale cache once and the new file once on a full rebuild over a stale cache" do
    write_cache("Gemfile.lock" => "old") # a non-.rb change forces a full rebuild
    fake_child("./spec/a_spec.rb[1:1]" => a_hit)

    expect(cache_reads { baseline.coverage_map }).to eq(2)
    expect(baseline.last_refresh).to eq(:full)
  end
end
