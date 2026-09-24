module ActiveMutator
  module Reporter
    # GitHub Actions workflow-command projection (issue #19): one ::warning
    # annotation per surviving mutant, inlined on the PR diff. Everything
    # else mirrors the terminal reporter so CI logs stay readable.
    class Github
      def initialize(root:, out: $stdout)
        @root = root
        @terminal = Terminal.new(out: out)
        @out = out
      end

      def on_result(result) = @terminal.on_result(result)

      def summary(results, invalid_count:, empty_plan: false, aborted: nil)
        @terminal.summary(results, invalid_count: invalid_count, empty_plan: empty_plan, aborted: aborted)
        results.select { |r| r.status == :survived }.each { |r| annotate(r) }
        annotate_abort(aborted, results) if aborted
      end

      private

      # One annotation for the whole run, after the survivors that did finish.
      def annotate_abort(aborted, results)
        reason = Terminal::ABORT_LABELS.fetch(aborted[:reason])
        lines = ["The run stopped early (#{reason}), so this is not a full result."]
        in_flight = aborted[:in_flight].map { |entry| Terminal.in_flight_label(entry) }
        lines << "In flight: #{in_flight.join("; ")}" unless in_flight.empty?
        lines << "Partial mutation score: #{Terminal.partial_score(results, aborted[:planned])}"
        @out.puts "::error title=Mutation run aborted::#{encode(lines.join("\n"))}"
      end

      def annotate(result)
        m = result.mutation
        file = m.subject.file.delete_prefix(@root.chomp("/") + "/")
        # Newlines survive percent-encoding, so the annotation renders as a
        # small diff instead of a pipe-separated one-liner.
        message = <<~MSG.chomp
          #{m.subject.name}: #{m.description}
          - #{m.original_snippet}
          + #{m.edit.replacement}
          Every test still passed after this change. Add or strengthen a test that fails when it's applied.
        MSG
        @out.puts "::warning file=#{file},line=#{m.line},title=Surviving mutant::#{encode(message)}"
      end

      # GitHub workflow commands terminate at a raw newline; percent-encode
      # per https://github.com/actions/toolkit runner rules.
      def encode(message)
        message.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      end
    end
  end
end
