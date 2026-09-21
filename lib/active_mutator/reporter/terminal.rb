module ActiveMutator
  module Reporter
    class Terminal
      CHARS = { killed: ".", survived: "S", timeout: "T", error: "E", uncovered: "U", accepted: "A",
                skipped: "-" }.freeze

      def initialize(out: $stdout)
        @out = out
      end

      def on_result(result)
        @out.print(CHARS.fetch(result.status))
      end

      # Every status key is present (zero when absent) so the block has the same
      # shape on every run, including an empty plan.
      def self.counts(results)
        tallies = results.group_by(&:status).transform_values(&:size)
        CHARS.keys.to_h { |status| [status, tallies.fetch(status, 0)] }
      end

      # `empty_plan: true` means a --since/--subject scope planned nothing: the
      # count block still prints, but there is no score to report (#45).
      def summary(results, invalid_count:, empty_plan: false)
        counts = self.class.counts(results)
        @out.puts "", ""
        counts.each { |status, count| @out.puts "#{status}: #{count}" }
        @out.puts "invalid (discarded): #{invalid_count}"
        @out.puts format("Mutation score: %.1f%%", score(counts) * 100) unless empty_plan
        print_group("Surviving mutants:", results.select { |r| r.status == :survived })
        print_group("Errored mutants (not detected):", results.select { |r| r.status == :error })
        print_group("Timed-out mutants (counted as detected):", results.select { |r| r.status == :timeout })
        skipped = results.select { |r| r.status == :skipped }
        print_skipped(skipped) unless skipped.empty?
        stats = OperatorStats.call(results)
        noisy = stats.select { |_, s| s["survived"].positive? }
        print_operator_stats(noisy) unless noisy.empty?
      end

      # A timeout is a detection (the mutant changed behavior enough to hang,
      # the same convention as Stryker and PIT). An error is a non-verdict:
      # scoring it as a pass let a broken worker read as 100%.
      def self.score(counts)
        detected = counts.fetch(:killed, 0) + counts.fetch(:timeout, 0)
        denominator = detected + counts.fetch(:survived, 0) + counts.fetch(:error, 0)
        return 1.0 if denominator.zero?

        detected.to_f / denominator
      end

      private

      def score(counts) = self.class.score(counts)

      def print_operator_stats(stats)
        @out.puts "", "Equivalent-rate by operator (survived / (killed + survived)):"
        stats.sort_by { |_, s| -s["equivalent_rate"] }.each do |operator, s|
          @out.puts format("  %-24s %5.1f%%  (%d survived / %d killed)",
                           operator, s["equivalent_rate"] * 100, s["survived"], s["killed"])
        end
      end

      def print_group(title, group)
        return if group.empty?

        @out.puts "", title
        group.each do |result|
          m = result.mutation
          @out.puts "", "  #{m.subject.name} (#{m.subject.file}:#{m.line})"
          @out.puts "    #{m.description}"
          @out.puts "    - #{m.original_snippet}"
          @out.puts "    + #{m.edit.replacement}"
          @out.puts "    (#{result.details})" if result.details
        end
      end

      def print_skipped(skipped)
        @out.puts "", "Skipped mutants (not counted in the score):"
        skipped.each do |result|
          m = result.mutation
          @out.puts "  #{m.subject.name} (#{m.subject.file}:#{m.line}): #{result.details}"
        end
      end
    end
  end
end
