require "tmpdir"
require "json"

RSpec.describe OpenMutator::CoverageMap do
  subject(:map) do
    described_class.new(
      "map" => {
        "/root/lib/a.rb:3" => ["spec/a_spec.rb[1:1]", "spec/b_spec.rb[1:1]"],
        "/root/lib/a.rb:4" => ["spec/a_spec.rb[1:1]"]
      },
      "times" => { "spec/a_spec.rb[1:1]" => 0.5, "spec/b_spec.rb[1:1]" => 0.25 },
      "digests" => { "lib/a.rb" => "abc" }
    )
  end

  it "returns the union of examples across lines" do
    expect(map.examples_for("/root/lib/a.rb", 3..4))
      .to contain_exactly("spec/a_spec.rb[1:1]", "spec/b_spec.rb[1:1]")
  end

  it "returns [] for uncovered lines" do
    expect(map.examples_for("/root/lib/a.rb", 99..99)).to eq([])
  end

  it "sums known example times" do
    expect(map.time_for(["spec/a_spec.rb[1:1]", "spec/b_spec.rb[1:1]", "unknown"]))
      .to eq(0.75)
  end

  it "treats recorded-but-nil times as zero" do
    nil_map = described_class.new(
      "map" => {}, "times" => { "spec/n_spec.rb[1:1]" => nil }, "digests" => {}
    )
    expect(nil_map.time_for(["spec/n_spec.rb[1:1]"])).to eq(0.0)
  end

  it "checks freshness against digests" do
    expect(map.fresh?("lib/a.rb" => "abc")).to be(true)
    expect(map.fresh?("lib/a.rb" => "zzz")).to be(false)
  end

  it "loads from a JSON file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "coverage.json")
      File.write(path, JSON.generate("map" => {}, "times" => {}, "digests" => {}))
      expect(described_class.load(path).examples_for("/x.rb", 1..1)).to eq([])
    end
  end
end
