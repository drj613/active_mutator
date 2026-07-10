module ActiveMutator
  # Line-number-independent identity for a mutant, used by the acceptance
  # ledger. `ordinal` disambiguates byte-identical mutants within one subject
  # (e.g. the two `>` in `a > 0 && b > 0`) by source order — without it,
  # accepting one would silently accept both.
  Fingerprint = Data.define(:file, :subject, :description, :original_snippet, :ordinal) do
    def self.for_mutations(mutations, root:)
      counters = Hash.new(0)
      mutations.sort_by { |m| [m.subject.name, m.edit.range.begin] }.to_h do |m|
        key = [m.subject.name, m.description, m.original_snippet]
        ordinal = counters[key]
        counters[key] += 1
        [m, new(file: m.subject.file.delete_prefix("#{root}/"),
                subject: m.subject.name,
                description: m.description,
                original_snippet: m.original_snippet,
                ordinal: ordinal)]
      end
    end
  end
end
