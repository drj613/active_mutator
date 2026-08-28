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

      def summary(results, invalid_count:)
        @terminal.summary(results, invalid_count: invalid_count)
        results.select { |r| r.status == :survived }.each { |r| annotate(r) }
      end

      private

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
