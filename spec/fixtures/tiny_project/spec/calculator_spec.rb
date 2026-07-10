RSpec.describe Calculator do
  subject(:calc) { Calculator.new }

  describe "#eligible?" do
    it { expect(calc.eligible?(18)).to eq("yes") }
    it { expect(calc.eligible?(19)).to eq("yes") }
    it { expect(calc.eligible?(10)).to eq("no") }
  end

  describe "#discount" do
    it { expect(calc.discount(50)).to eq(0) }
    it { expect(calc.discount(200)).to eq(20) }
    # NOTE: no test at exactly 100 — the `<` → `<=` and `100` → `101`
    # mutants survive. Planted on purpose.
  end
end
