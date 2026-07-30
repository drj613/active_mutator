RSpec.describe ActiveMutator::ClassShape do
  def program(source) = Prism.parse(source).value

  describe ".single_top_level_constant?" do
    it "is true for a single top-level class" do
      expect(described_class.single_top_level_constant?(program("class A\n  X = 1\nend\n"))).to be(true)
    end

    it "is true for a single top-level module" do
      expect(described_class.single_top_level_constant?(program("module A\nend\n"))).to be(true)
    end

    it "is false for two top-level classes" do
      expect(described_class.single_top_level_constant?(program("class A\nend\nclass B\nend\n"))).to be(false)
    end

    it "counts a top-level constant assignment alongside a class (false)" do
      expect(described_class.single_top_level_constant?(program("class A\nend\nB = Class.new\n"))).to be(false)
    end

    it "counts a top-level constant-path assignment alongside a class (false)" do
      expect(described_class.single_top_level_constant?(program("class A\nend\nFoo::B = 1\n"))).to be(false)
    end

    it "is true for a lone top-level constant assignment" do
      expect(described_class.single_top_level_constant?(program("A = Class.new\n"))).to be(true)
    end

    it "ignores constants nested inside the single top-level class" do
      expect(described_class.single_top_level_constant?(program("class A\n  X = 1\n  Y = 2\nend\n"))).to be(true)
    end

    it "is false for an empty file (zero constants)" do
      expect(described_class.single_top_level_constant?(program("puts 1\n"))).to be(false)
    end
  end

  describe ".owned_by_other_subject?" do
    {
      "def m; end" => true, "class C; end" => true, "module M; end" => true,
      "class << self; end" => true, "validates :x" => false, "X = 1" => false
    }.each do |source, owned|
      it "returns #{owned} for `#{source}`" do
        node = Prism.parse(source).value.statements.body.first
        expect(described_class.owned_by_other_subject?(node)).to be(owned)
      end
    end
  end
end
