require "json"

module OpenMutator
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
          "results" => results.map { |r| serialize(r) }
        )
      end

      private

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
