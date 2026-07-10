require "json"
require "set"

module OpenMutator
  # Committed, repo-root ledger of accepted (equivalent) survivors.
  # Deliberately NOT inside .open_mutator/ — that dir is gitignored and
  # disposable, while acceptance decisions are durable team/CI state.
  class AcceptedLedger
    FILENAME = ".open_mutator_accepted.json"

    def self.load(root)
      path = File.join(root, FILENAME)
      entries = File.exist?(path) ? JSON.parse(File.read(path)) : []
      new(path, entries.map { |e| from_hash(e) })
    end

    def self.from_hash(hash)
      Fingerprint.new(file: hash.fetch("file"), subject: hash.fetch("subject"),
                      description: hash.fetch("description"),
                      original_snippet: hash.fetch("original_snippet"),
                      ordinal: hash.fetch("ordinal"))
    end

    def initialize(path, entries)
      @path = path
      @entries = entries
    end

    def accepted?(fingerprint) = @entries.include?(fingerprint)

    def stale_entries(all_current_fingerprints)
      current = all_current_fingerprints.to_set
      @entries.reject { |e| current.include?(e) }
    end

    # Union new acceptances in, prune anything no longer matching a current
    # mutant, write atomically.
    def accept!(new_fingerprints, all_current_fingerprints)
      current = all_current_fingerprints.to_set
      @entries = (@entries + new_fingerprints).uniq.select { |e| current.include?(e) }
      AtomicFile.write(@path, JSON.pretty_generate(@entries.map(&:to_h)))
      nil
    end
  end
end
