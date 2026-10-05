module ActiveMutator
  # --max-rss: a ceiling on the gem's total memory (the parent, its workers,
  # and the baseline child), read from the sampler's `memory` events. Warns
  # once at 90%. At 100% it trips the abort flag, and whoever owns the
  # running processes kills them, so the run ends with exit 3 and a partial
  # score instead of an OOM kill that leaves nothing.
  class MemoryCeiling
    SIZE = /\A(\d+(?:\.\d+)?)([gm]?)\z/i
    WARN_AT = 0.9
    # Parsing coverage.json peaked at about 5x the file's size (7x with the
    # CoverageMap built from it). JSON.parse holds Ruby's global lock, so
    # no sample or signal gets through until it returns: the size is checked
    # before the parse instead.
    PARSE_COST = 5

    # "6G", "6144M", or plain MB ("6144") to kB; nil for anything else.
    def self.parse_kb(text)
      match = SIZE.match(text.to_s.strip)
      return unless match

      mb = Float(match[1]) * (match[2].casecmp?("g") ? 1024 : 1)
      kb = (mb * 1024).round
      kb if kb.positive?
    end

    def initialize(max_rss_kb:, events:, abort:)
      @max_rss_kb = max_rss_kb
      @events = events
      @abort = abort
    end

    # Events listener. Runs on whichever thread emitted the sample.
    def call(event)
      fields = event.fields
      if event.type == :memory
        @last_total_kb = fields[:total_pss_kb] || @last_total_kb
        check(fields[:total_pss_kb])
      elsif event.type == :phase_start && fields[:phase] == :coverage_load
        check(@last_total_kb.to_i + (fields[:bytes] / 1024 * PARSE_COST), coverage_bytes: fields[:bytes])
      end
    end

    private

    # Quiet once the run is stopping: samples keep coming until it exits.
    def check(total_kb, **extra)
      return if total_kb.nil? || @abort.tripped?

      fields = { total_pss_kb: total_kb, max_rss_kb: @max_rss_kb, **extra }
      if total_kb >= @max_rss_kb
        @events.emit(:memory_ceiling, **fields)
        @abort.trip!(:memory_ceiling)
      elsif !@warned && total_kb >= @max_rss_kb * WARN_AT
        @warned = true
        @events.emit(:memory_warning, **fields)
      end
    end
  end
end
