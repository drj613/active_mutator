require "spec_helper"

RSpec.describe ActiveMutator::SourceLocation do
  let(:source) { "def a\n  x > 1\nend\n" }

  it "locates a mid-file span with 1-based line and column" do
    # bytes 10...11 is ">" on line 2, column 5
    loc = described_class.locate(source, 10...11)
    expect(loc).to eq(start: { line: 2, column: 5 }, end: { line: 2, column: 6 })
  end

  it "locates a span at byte 0 as line 1 column 1" do
    loc = described_class.locate(source, 0...3)
    expect(loc[:start]).to eq(line: 1, column: 1)
  end

  it "handles a span crossing a newline" do
    # "1\nend" — starts line 2, ends line 3
    loc = described_class.locate(source, 12...17)
    expect(loc[:start][:line]).to eq(2)
    expect(loc[:end][:line]).to eq(3)
  end
end
