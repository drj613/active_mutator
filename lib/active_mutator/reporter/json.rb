require "json"

module ActiveMutator
  module Reporter
    class Json
      def initialize(out: $stdout)
        @out = out
      end

      def on_result(result); end

      def summary(results, invalid_count:)
        counts = results.group_by(&:status).transform_values(&:size)
        @out.puts JSON.pretty_generate(
          "score" => Terminal.score(counts),
          "counts" => counts.transform_keys(&:to_s),
          "invalid" => invalid_count,
          "operators" => OperatorStats.call(results),
          "results" => results.map { |r| serialize(r) },
          "exit_reason" => exit_reason(counts)
        )
      end

      private

      def exit_reason(counts)
        return "unaccepted_survivors" if counts.fetch(:survived, 0).positive?
        return "worker_errors" if counts.fetch(:error, 0).positive?

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
