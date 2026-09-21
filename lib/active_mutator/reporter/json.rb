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
      def summary(results, invalid_count:, empty_plan: false)
        counts = Terminal.counts(results)
        @out.puts JSON.pretty_generate(
          "score" => empty_plan ? nil : Terminal.score(counts),
          "counts" => counts.transform_keys(&:to_s),
          "invalid" => invalid_count,
          "operators" => OperatorStats.call(results),
          "results" => results.map { |r| serialize(r) },
          "exit_reason" => exit_reason(counts, empty_plan)
        )
      end

      private

      def exit_reason(counts, empty_plan)
        return "empty_plan" if empty_plan
        return "unaccepted_survivors" if counts[:survived].positive?
        return "worker_errors" if counts[:error].positive?

        "clean"
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
          "details" => result.details
        }
      end
    end
  end
end
