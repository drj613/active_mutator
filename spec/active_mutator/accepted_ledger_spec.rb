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
      described_class.load(root).accept!([fp], [fp, fp(ordinal: 1)], scanned_files: ["lib/calc.rb"])
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(fp)).to be(true)
      expect(reloaded.accepted?(fp(ordinal: 1))).to be(false)
      expect(File.exist?(File.join(root, ".active_mutator_accepted.json"))).to be(true)
    end
  end

  it "prunes entries that no longer match any current mutant on accept!" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp], scanned_files: ["lib/calc.rb"])
      # Next accept with a current set that no longer contains fp:
      described_class.load(root).accept!([fp(ordinal: 1)], [fp(ordinal: 1)], scanned_files: ["lib/calc.rb"])
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(fp)).to be(false)
      expect(reloaded.accepted?(fp(ordinal: 1))).to be(true)
    end
  end

  it "keeps out-of-scope entries while adding new ones when scanned_files is nil" do
    Dir.mktmpdir do |root|
      other = fp(file: "lib/other.rb", subject: "Other#go")
      described_class.load(root).accept!([other], [other], scanned_files: ["lib/other.rb"])
      # Scoped run: `other` matches no current mutant, but nothing was fully scanned.
      described_class.load(root).accept!([fp], [fp], scanned_files: nil)
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(other)).to be(true)
      expect(reloaded.accepted?(fp)).to be(true)
    end
  end

  it "prunes stale entries only within the scanned files on accept!" do
    Dir.mktmpdir do |root|
      stale_in_scope = fp(ordinal: 1)
      out_of_scope = fp(file: "lib/other.rb", subject: "Other#go")
      described_class.load(root)
        .accept!([fp, stale_in_scope, out_of_scope], [fp, stale_in_scope, out_of_scope],
                 scanned_files: ["lib/calc.rb", "lib/other.rb"])
      # lib/calc.rb fully re-scanned; stale_in_scope no longer matches a mutant.
      described_class.load(root).accept!([], [fp], scanned_files: ["lib/calc.rb"])
      reloaded = described_class.load(root)
      expect(reloaded.accepted?(fp)).to be(true)
      expect(reloaded.accepted?(stale_in_scope)).to be(false)
      expect(reloaded.accepted?(out_of_scope)).to be(true)
    end
  end

  it "returns nil from accept! rather than leaking the writer's return value" do
    Dir.mktmpdir do |root|
      allow(ActiveMutator::AtomicFile).to receive(:write).and_return(:written)
      expect(described_class.load(root).accept!([fp], [fp], scanned_files: ["lib/calc.rb"])).to be_nil
    end
  end

  it "reports stale entries without mutating the file" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp], scanned_files: ["lib/calc.rb"])
      ledger = described_class.load(root)
      expect(ledger.stale_entries([fp(ordinal: 1)], scanned_files: ["lib/calc.rb"]).size).to eq(1)
      expect(described_class.load(root).accepted?(fp)).to be(true)
    end
  end

  it "reports only in-scope stale entries from stale_entries" do
    Dir.mktmpdir do |root|
      out_of_scope = fp(file: "lib/other.rb", subject: "Other#go")
      described_class.load(root).accept!([fp, out_of_scope], [fp, out_of_scope],
                                         scanned_files: ["lib/calc.rb", "lib/other.rb"])
      ledger = described_class.load(root)
      expect(ledger.stale_entries([], scanned_files: ["lib/calc.rb"])).to eq([fp])
    end
  end

  it "reports no stale entries when scanned_files is nil" do
    Dir.mktmpdir do |root|
      described_class.load(root).accept!([fp], [fp], scanned_files: ["lib/calc.rb"])
      ledger = described_class.load(root)
      expect(ledger.stale_entries([], scanned_files: nil)).to eq([])
    end
  end
end
