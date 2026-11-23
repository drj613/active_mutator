require "json"

module ActiveMutator
  module Reporter
    class Json
      def initialize(out: $stdout)
        @out = out
      end

      def on_result(result); end

      # An empty plan has no score (null) and its own exit_reason, so a CI
      # consumer can tell "nothing to mutate" from "everything was killed" (#45).
      # An aborted run has `complete: false`, and its score covers only the
      # mutants that finished (null if none did). `test_audit` is null unless
      # --audit-tests ran.
      def summary(results, invalid_count:, empty_plan: false, aborted: nil, test_audit: nil)
        counts = Terminal.counts(results)
        @out.puts JSON.pretty_generate(
          "complete" => aborted.nil?,
          "score" => score(results, counts, empty_plan, aborted),
          "counts" => counts.transform_keys(&:to_s),
          "invalid" => invalid_count,
          "operators" => OperatorStats.call(results),
          "results" => results.map { |r| serialize(r) },
          "in_flight" => aborted ? aborted[:in_flight] : [],
          "planned" => aborted ? aborted[:planned] : results.size,
          "exit_reason" => exit_reason(counts, empty_plan, aborted, test_audit),
          "test_audit" => test_audit && serialize_audit(test_audit)
        )
      end

      private

      def score(results, counts, empty_plan, aborted)
        return nil if empty_plan || (aborted && results.empty?)

        Terminal.score(counts)
      end

      def exit_reason(counts, empty_plan, aborted, test_audit)
        return aborted[:reason] == :memory_ceiling ? "memory_ceiling" : "interrupted" if aborted
        return "empty_plan" if empty_plan
        return "unaccepted_survivors" if counts[:survived].positive?
        return "worker_errors" if counts[:error].positive?
        return "no_kills_observed" if test_audit&.failing?

        "clean"
      end

      def serialize_audit(report)
        {
          "mutants_run" => report.mutants_run,
          "cleared" => report.cleared,
          "no_kills_observed" => report.flagged.map do |flag|
            { "id" => flag.id, "location" => flag.location, "killable_mutants" => flag.killable, "kills" => 0 }
          end,
          "ignored" => report.ignored,
          "not_judged" => report.not_judged
        }
      end

      def serialize(result)
        m = result.mutation
        {
          "subject" => m.subject.name,
          "status" => result.status.to_s,
          "description" => m.description,
          "file" => m.subject.file,
          "line" => m.line,
          "original" => m.original_snippet,
          "replacement" => m.edit.replacement,
          "details" => result.details,
          "killed_by" => result.killed_by,
          "seconds" => result.seconds,
          "peak_rss_kb" => result.peak_rss_kb
        }
      end
    end
  end
end
