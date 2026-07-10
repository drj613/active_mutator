require "tmpdir"
require "json"

RSpec.describe ActiveMutator::AcceptedLedger do
  def fp(ordinal: 0, file: "lib/calc.rb", subject: "Calc#go")
    ActiveMutator::Fingerprint.new(file: file, subject: subject,
                                 description: "replace `>` with `>=`",
                                 original_snippet: ">", ordinal: ordinal)
  end

  it "loads an empty ledger when the file is absent" do
    Dir.mktmpdir do |root|
      ledger = described_class.load(root)
      expect(ledger.accepted?(fp)).to be(false)
    end
  end

  it "round-trips acceptance" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp, fp(ordinal: 1)])
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(fp)).to be(true)
      expect(reloaded.accepted?(fp(ordinal: 1))).to be(false)
      expect(File.exist?(File.join(root, ".active_mutator_accepted.json"))).to be(true)
    end
  end

  it "prunes entries that no longer match any current mutant on accept!" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp])
      # Next accept with a current set that no longer contains fp:
      described_class.load(root).accept!([fp(ordinal: 1)], [fp(ordinal: 1)])
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(fp)).to be(false)
      expect(reloaded.accepted?(fp(ordinal: 1))).to be(true)
    end
  end

  it "reports stale entries without mutating the file" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp])
      ledger = described_class.load(root)
      expect(ledger.stale_entries([fp(ordinal: 1)]).size).to eq(1)
      expect(described_class.load(root).accepted?(fp)).to be(true)
    end
  end
end
