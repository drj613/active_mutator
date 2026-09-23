module ActiveMutator
  module Diagnostics
    # Human sizes for diagnostic lines: 812M, 1.6G. nil (no reading) is "?".
    def self.size_kb(kb)
      return "?" unless kb
      return format("%.1fG", kb / 1_048_576.0) if kb >= 1_048_576
      return "#{(kb / 1024.0).round}M" if kb >= 1024

      "#{kb}K"
    end

    # --diagnostics: one human-readable line per event, on stderr. stdout
    # belongs to the reporter (`--format json` must stay parseable).
    class Text
      def initialize(root:, out: $stderr)
        @prefix = "#{root.chomp("/")}/"
        @out = out
      end

      def call(event)
        stamp = "[active_mutator #{event.at.strftime("%H:%M:%S")} +#{format("%.1f", event.elapsed)}s]"
        @out.puts "#{stamp} #{body(event.type, event.fields)}"
      end

      private

      def body(type, fields)
        case type
        when :phase_start, :phase_end then phase(type, fields)
        when :mutant_start then mutant_start(fields)
        when :mutant_end then mutant_end(fields)
        else [type, *pairs(fields)].join(" ")
        end
      end

      def phase(type, fields)
        edge = type == :phase_start ? "start" : "end"
        ["phase", fields[:phase], edge, *pairs(fields.except(:phase))].join(" ")
      end

      def mutant_start(f)
        "mutant start ##{f[:seq]} pid=#{f[:pid]} #{f[:lane]} #{f[:subject]} " \
          "#{f[:file].delete_prefix(@prefix)}:#{f[:line]} #{f[:description]}"
      end

      def mutant_end(f)
        "mutant end ##{f[:seq]} #{f[:status]} #{format("%.1f", f[:seconds])}s peak=#{Diagnostics.size_kb(f[:peak_rss_kb])}"
      end

      def pairs(fields)
        fields.map do |key, value|
          key == :bytes ? "size=#{Diagnostics.size_kb((value / 1024.0).round)}" : "#{key}=#{value}"
        end
      end
    end
  end
end
