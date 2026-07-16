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
        message = "#{m.subject.name}: #{m.description} | - #{m.original_snippet} | + #{m.edit.replacement}"
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
