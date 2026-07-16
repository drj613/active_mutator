require "json"
require "set"

module ActiveMutator
  # Committed, repo-root ledger of accepted (equivalent) survivors.
  # Deliberately NOT inside .active_mutator/: that dir is gitignored and
  # disposable, while acceptance decisions are durable team/CI state.
  class AcceptedLedger
    FILENAME = ".active_mutator_accepted.json"

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

    # Entries outside the scanned files can't be judged by this run, so they
    # are never stale here. scanned_files: nil means "no file was fully
    # scanned" (subject-level filtering active) — union only, prune nothing.
    # See #24: a scoped accept run once deleted every out-of-scope entry.
    def stale_entries(all_current_fingerprints, scanned_files:)
      return [] if scanned_files.nil?

      current = all_current_fingerprints.to_set
      scanned = scanned_files.to_set
      @entries.reject { |e| current.include?(e) || !scanned.include?(e.file) }
    end

    def accept!(new_fingerprints, all_current_fingerprints, scanned_files:)
      stale = stale_entries(all_current_fingerprints, scanned_files: scanned_files).to_set
      @entries = (@entries + new_fingerprints).uniq.reject { |e| stale.include?(e) }
      AtomicFile.write(@path, JSON.pretty_generate(@entries.map(&:to_h)))
      nil
    end
  end
end
