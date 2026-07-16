RSpec.describe ActiveMutator::SubjectMatcher do
  def match?(expr, name) = described_class.new(expr).match?(name)

  it("exact instance")         { expect(match?("Foo::Bar#baz", "Foo::Bar#baz")).to be true }
  it("exact rejects other")    { expect(match?("Foo::Bar#baz", "Foo::Bar#qux")).to be false }
  it("bare constant, all")     { expect(match?("Foo::Bar", "Foo::Bar#baz")).to be true }
  it("bare constant, dot")     { expect(match?("Foo::Bar", "Foo::Bar.build")).to be true }
  it("bare rejects nested")    { expect(match?("Foo::Bar", "Foo::Bar::Qux#m")).to be false }
  it("bare rejects other")     { expect(match?("Foo::Bar", "Foo::Barn#m")).to be false }
  it("star namespace")         { expect(match?("Foo::Bar*", "Foo::Bar::Qux#m")).to be true }
  it("star same-prefix const") { expect(match?("Foo::Bar*", "Foo::Barn#m")).to be true }
  it("star exact const too")   { expect(match?("Foo::Bar*", "Foo::Bar#m")).to be true }
  it("hash star instance")     { expect(match?("Foo::Bar#*", "Foo::Bar#baz")).to be true }
  it("hash star not dot")      { expect(match?("Foo::Bar#*", "Foo::Bar.build")).to be false }
  it("hash star not nested")   { expect(match?("Foo::Bar#*", "Foo::Bar::Qux#m")).to be false }
  it("dot star singleton")     { expect(match?("Foo::Bar.*", "Foo::Bar.build")).to be true }
  it("dot star not hash")      { expect(match?("Foo::Bar.*", "Foo::Bar#baz")).to be false }
end
