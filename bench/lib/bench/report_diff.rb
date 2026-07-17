# Compares two mutation-testing-report-schema v2 JSONs (parsed Hashes).
# Pure stdlib; never required by the gem's runtime.
module Bench
  class ReportDiff
    DETECTED = %w[Killed Timeout].freeze
    SCOREABLE = %w[Killed Timeout Survived RuntimeError].freeze

    def initialize(report_a, report_b)
      @a = index(report_a)
      @b = index(report_b)
    end

    def call
      shared = @a.keys & @b.keys
      transitions = shared.filter_map do |key|
        from, to = @a[key], @b[key]
        { key: key, from: from, to: to } if from != to
      end
      {
        score_a: score(@a), score_b: score(@b),
        score_delta: (score(@b) - score(@a)).round(2),
        transitions: transitions.sort_by { |t| t[:key] },
        only_in_a: (@a.keys - @b.keys).sort,
        only_in_b: (@b.keys - @a.keys).sort
      }
    end

    private

    # {key => status}. Key must be stable across runs: location + operator + replacement.
    def index(report)
      report.fetch("files").flat_map do |file, entry|
        entry.fetch("mutants").map do |m|
          start = m.fetch("location").fetch("start")
          key = "#{file}:#{start["line"]}:#{start["column"]} " \
                "#{m["mutatorName"]} #{m["replacement"]}"
          [key, m.fetch("status")]
        end
      end.to_h
    end

    def score(indexed)
      statuses = indexed.values.select { |s| SCOREABLE.include?(s) }
      return 0.0 if statuses.empty?

      detected = statuses.count { |s| DETECTED.include?(s) }
      (detected * 100.0 / statuses.size).round(2)
    end
  end
end
