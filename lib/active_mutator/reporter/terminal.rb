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

      def summary(results, invalid_count:)
        counts = results.group_by(&:status).transform_values(&:size)
        @out.puts "", ""
        CHARS.each_key do |status|
          @out.puts "#{status}: #{counts.fetch(status, 0)}"
        end
        @out.puts "invalid (discarded): #{invalid_count}"
        @out.puts format("Mutation score: %.1f%%", score(counts) * 100)
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
