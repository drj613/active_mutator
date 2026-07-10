require "open_mutator/baseline_hooks"

RSpec.describe OpenMutator::BaselineHooks do
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
  end
end
