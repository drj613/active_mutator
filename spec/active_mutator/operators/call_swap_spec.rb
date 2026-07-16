RSpec.describe ActiveMutator::Operators::CallSwap do
  subject(:operator) { described_class.new }

  {
    "xs.map { |x| x }" => "xs.each { |x| x }",
    "xs.select(&:a?)" => "xs.reject(&:a?)",
    "xs.reject(&:a?)" => "xs.select(&:a?)",
    "xs.min" => "xs.max",
    "xs.max" => "xs.min",
    "xs.first" => "xs.last",
    "xs.last" => "xs.first",
    "xs.any?" => "xs.none?",
    "xs.none?" => "xs.any?",
    "x.present?" => "x.blank?",
    "x.blank?" => "x.present?",
    "x.save" => "x.save!",
    "x.save!" => "x.save"
  }.each do |from, to|
    it "mutates #{from} to #{to}" do
      expect(mutations_of(from, operator)).to eq([to])
    end
  end

  it "ignores unmapped calls" do
    expect(mutations_of("xs.compact", operator)).to eq([])
  end

  it "ignores receiverless calls with mapped names" do
    expect(mutations_of("min", operator)).to eq([])
    expect(mutations_of("map { |x| x }", operator)).to eq([])
  end
end
