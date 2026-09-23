module ActiveMutator
  # --max-rss: a ceiling on the gem's total memory (the parent, its workers,
  # and the baseline child).
  class MemoryCeiling
    SIZE = /\A(\d+(?:\.\d+)?)([gm]?)\z/i

    # "6G", "6144M", or plain MB ("6144") to kB; nil for anything else.
    def self.parse_kb(text)
      match = SIZE.match(text.to_s.strip)
      return unless match

      mb = Float(match[1]) * (match[2].casecmp?("g") ? 1024 : 1)
      kb = (mb * 1024).round
      kb if kb.positive?
    end
  end
end
