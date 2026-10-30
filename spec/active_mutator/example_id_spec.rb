RSpec.describe ActiveMutator::ExampleId do
  let(:abs) { File.expand_path("spec/a_spec.rb") }

  describe ".group_key" do
    it "is the absolute file and the top-level group number" do
      expect(described_class.group_key("./spec/a_spec.rb[1:2:3]")).to eq([abs, "1"])
    end

    it "gives nested examples of one top-level group the same key" do
      keys = %w[./spec/a_spec.rb[2] ./spec/a_spec.rb[2:1] ./spec/a_spec.rb[2:4:1:7]].map { |id| described_class.group_key(id) }
      expect(keys.uniq).to eq([[abs, "2"]])
    end

    it "separates top-level groups of the same file" do
      expect(described_class.group_key("./spec/a_spec.rb[1:1]")).not_to eq(described_class.group_key("./spec/a_spec.rb[2:1]"))
    end

    it "treats ./ relative, bare relative, and absolute spellings alike" do
      keys = ["./spec/a_spec.rb[1:1]", "spec/a_spec.rb[1:1]", "#{abs}[1:1]"].map { |id| described_class.group_key(id) }
      expect(keys.uniq).to eq([[abs, "1"]])
    end

    it "reads shared-example ids with a second bracket as their including group" do
      expect(described_class.group_key("./spec/a_spec.rb[3:1][1:2]")).to eq([abs, "3"])
    end

    it "keeps a bracket inside the file name in the file" do
      expect(described_class.group_key("./spec/[x]_spec.rb[1:1]")).to eq([File.expand_path("spec/[x]_spec.rb"), "1"])
    end

    [nil, 12, "", "./spec/a_spec.rb", "./spec/a_spec.rb[]", "./spec/a_spec.rb[x:1]", "./spec/a_spec.rb[1:]",
     "[1:1]", "./spec/a_spec.rb[1:1", "./spec/a_spec.rb[1,2]"].each do |bad|
      it "is nil for the malformed id #{bad.inspect}" do
        expect(described_class.group_key(bad)).to be_nil
      end
    end
  end

  describe ".normalize" do
    it "makes ./ and absolute spellings of one example equal" do
      expect(described_class.normalize("./spec/a_spec.rb[1:2]")).to eq("#{abs}[1:2]")
      expect(described_class.normalize("#{abs}[1:2]")).to eq("#{abs}[1:2]")
    end

    it "keeps the shared-example suffix" do
      expect(described_class.normalize("./spec/a_spec.rb[1:2][1:1]")).to eq("#{abs}[1:2][1:1]")
    end

    it "is nil for malformed ids" do
      expect(described_class.normalize("./spec/a_spec.rb")).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end
  end
end
