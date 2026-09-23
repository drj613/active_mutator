require "active_mutator/baseline_hooks"

RSpec.describe ActiveMutator::BaselineHooks do
  it "initializes RECORDS and TIMES as empty hashes" do
    expect(described_class::RECORDS).to be_a(Hash)
    expect(described_class::TIMES).to be_a(Hash)
  end

  describe ".diff_coverage" do
    it "returns [path, line] pairs whose hit count increased" do
      before = { "/root/lib/a.rb" => { lines: [1, 0, nil, 2] } }
      after  = { "/root/lib/a.rb" => { lines: [1, 1, nil, 5] } }
      expect(described_class.diff_coverage(before, after, "/root"))
        .to contain_exactly(["/root/lib/a.rb", 2], ["/root/lib/a.rb", 4])
    end

    it "includes files first seen after the example started" do
      after = { "/root/lib/b.rb" => { lines: [nil, 1] } }
      expect(described_class.diff_coverage({}, after, "/root"))
        .to eq([["/root/lib/b.rb", 2]])
    end

    it "ignores files outside the project root and spec files" do
      after = {
        "/gems/x.rb" => { lines: [1] },
        "/root/spec/a_spec.rb" => { lines: [1] },
        "/root/lib/a.rb" => { lines: [1] }
      }
      expect(described_class.diff_coverage({}, after, "/root"))
        .to eq([["/root/lib/a.rb", 1]])
    end

    it "excludes files under configured spec paths from coverage hits" do
      after = {
        "/proj/test/a_spec.rb" => { lines: [1] },
        "/proj/lib/a.rb" => { lines: [1] }
      }
      hits = described_class.diff_coverage({}, after, "/proj", spec_paths: ["test"])
      expect(hits.map(&:first)).to eq(["/proj/lib/a.rb"])
    end

    it "defaults spec_paths to spec/" do
      after = { "/proj/spec/a_spec.rb" => { lines: [1] } }
      expect(described_class.diff_coverage({}, after, "/proj")).to be_empty
    end

    it "excludes files under gem dirs even when they sit inside the root" do
      after = {
        "/proj/vendor/bundle/ruby/3.3.0/gems/x/lib/x.rb" => { lines: [1] },
        "/proj/lib/a.rb" => { lines: [1] }
      }
      hits = described_class.diff_coverage({}, after, "/proj",
                                           gem_dirs: ["/proj/vendor/bundle/ruby/3.3.0"])
      expect(hits.map(&:first)).to eq(["/proj/lib/a.rb"])
    end

    it "matches gem dirs on whole path segments" do
      after = { "/proj/vendor/bundle_notes/a.rb" => { lines: [1] } }
      hits = described_class.diff_coverage({}, after, "/proj", gem_dirs: ["/proj/vendor/bundle"])
      expect(hits.map(&:first)).to eq(["/proj/vendor/bundle_notes/a.rb"])
    end
  end

  describe ".gem_dirs" do
    it "includes every Gem.path entry" do
      allow(Gem).to receive(:path).and_return(["/home/u/.gem", "/proj/vendor/bundle/ruby/3.3.0"])
      expect(described_class.gem_dirs).to include("/home/u/.gem", "/proj/vendor/bundle/ruby/3.3.0")
    end

    it "includes the Bundler install path" do
      allow(Bundler).to receive(:bundle_path).and_return(Pathname.new("/proj/vendor/bundle/ruby/3.3.0"))
      expect(described_class.gem_dirs).to include("/proj/vendor/bundle/ruby/3.3.0")
    end

    it "falls back to Gem.path when Bundler has no Gemfile" do
      allow(Bundler).to receive(:bundle_path).and_raise(Bundler::GemfileNotFound)
      allow(Gem).to receive(:path).and_return(["/home/u/.gem"])
      expect(described_class.gem_dirs).to eq(["/home/u/.gem"])
    end
  end

  describe ".build_payload" do
    it "emits version-2 primary records" do
      records = { "spec/a_spec.rb[1:1]" => [["/root/lib/a.rb", 3]] }
      times = { "spec/a_spec.rb[1:1]" => 0.5 }
      payload = described_class.build_payload(records, times)
      expect(payload["version"]).to eq(2)
      expect(payload["records"]).to eq(records)
      expect(payload["times"]).to eq(times)
      expect(payload).not_to have_key("map")
    end

    it "records the expected example count when given" do
      payload = described_class.build_payload({}, {}, expected_examples: 7)
      expect(payload["expected_examples"]).to eq(7)
    end

    it "omits the expected example count when unknown" do
      expect(described_class.build_payload({}, {})).not_to have_key("expected_examples")
    end
  end
end
