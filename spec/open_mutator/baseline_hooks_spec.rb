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
    it "inverts per-example hits into a line index" do
      records = {
        "spec/a_spec.rb[1:1]" => [["/root/lib/a.rb", 3], ["/root/lib/a.rb", 4]],
        "spec/a_spec.rb[1:2]" => [["/root/lib/a.rb", 3]]
      }
      times = { "spec/a_spec.rb[1:1]" => 0.5, "spec/a_spec.rb[1:2]" => 0.1 }
      payload = described_class.build_payload(records, times)
      expect(payload["map"]["/root/lib/a.rb:3"])
        .to contain_exactly("spec/a_spec.rb[1:1]", "spec/a_spec.rb[1:2]")
      expect(payload["map"]["/root/lib/a.rb:4"]).to eq(["spec/a_spec.rb[1:1]"])
      expect(payload["times"]).to eq(times)
    end
  end
end
