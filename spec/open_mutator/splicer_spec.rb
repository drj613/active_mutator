RSpec.describe OpenMutator::Splicer do
  def edit(range, replacement)
    OpenMutator::Edit.new(range: range, replacement: replacement, description: "test")
  end

  it "replaces a byte range" do
    expect(described_class.apply("a >= b", [edit(2...4, ">")])).to eq("a > b")
  end

  it "applies multiple edits without offset drift" do
    src = "x + y + z"
    edits = [edit(0...1, "AA"), edit(8...9, "BB")]
    expect(described_class.apply(src, edits)).to eq("AA + y + BB")
  end

  it "splices bytewise in multibyte source" do
    src = %(name = "héllo"\nn > 0)
    # "é" is 2 bytes; ">" sits at byte offset 18
    expect(src.byteslice(18, 1)).to eq(">")
    expect(described_class.apply(src, [edit(18...19, ">=")])).to eq(%(name = "héllo"\nn >= 0))
  end

  it "preserves the source encoding" do
    out = described_class.apply("a > b", [edit(2...3, ">=")])
    expect(out.encoding).to eq(Encoding::UTF_8)
    expect(out).to be_valid_encoding
  end

  it "supports deletion via empty replacement" do
    expect(described_class.apply("a + b", [edit(1...5, "")])).to eq("a")
  end
end
