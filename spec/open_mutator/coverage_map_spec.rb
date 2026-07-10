require "tmpdir"
require "json"

RSpec.describe OpenMutator::CoverageMap do
  subject(:map) do
    described_class.new(
      "version" => 2,
      "records" => {
        "./spec/a_spec.rb[1:1]" => [["/root/lib/a.rb", 3], ["/root/lib/a.rb", 4]],
        "./spec/b_spec.rb[1:1]" => [["/root/lib/a.rb", 3], ["/root/lib/b.rb", 9]]
      },
      "times" => { "./spec/a_spec.rb[1:1]" => 0.5, "./spec/b_spec.rb[1:1]" => 0.25 },
      "digests" => { "lib/a.rb" => "abc" }
    )
  end

  it "derives the inverted index from records" do
    expect(map.examples_for("/root/lib/a.rb", 3..4))
      .to contain_exactly("./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]")
    expect(map.examples_for("/root/lib/b.rb", 9..9)).to eq(["./spec/b_spec.rb[1:1]"])
    expect(map.examples_for("/root/lib/a.rb", 99..99)).to eq([])
  end

  it "sums known example times, treating nil as zero" do
    expect(map.time_for(["./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]", "unknown"])).to eq(0.75)
    nil_map = described_class.new("version" => 2, "records" => {},
                                  "times" => { "x" => nil }, "digests" => {})
    expect(nil_map.time_for(["x"])).to eq(0.0)
  end

  it "is stale when digests differ or version is not 2" do
    expect(map.fresh?("lib/a.rb" => "abc")).to be(true)
    expect(map.fresh?("lib/a.rb" => "zzz")).to be(false)
    v1 = described_class.new("map" => {}, "times" => {}, "digests" => {})
    expect(v1.version).to be_nil
    expect(v1.fresh?({})).to be(false)
  end

  it "finds examples covering a source file" do
    expect(map.examples_covering_file("/root/lib/b.rb")).to eq(["./spec/b_spec.rb[1:1]"])
  end

  it "finds examples belonging to a spec file" do
    expect(map.examples_for_spec_file("spec/a_spec.rb")).to eq(["./spec/a_spec.rb[1:1]"])
  end

  it "loads from a JSON file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "coverage.json")
      File.write(path, JSON.generate("version" => 2, "records" => {}, "times" => {}, "digests" => {}))
      expect(described_class.load(path).examples_for("/x.rb", 1..1)).to eq([])
    end
  end
end
