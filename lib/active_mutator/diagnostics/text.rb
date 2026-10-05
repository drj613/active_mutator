module ActiveMutator
  module Diagnostics
    # Human sizes for diagnostic lines: 812M, 1.6G. nil (no reading) is "?".
    def self.size_kb(kb)
      return "?" unless kb
      return "0" if kb.zero?
      return format("%.1fG", kb / 1_048_576.0) if kb >= 1_048_576
      return "#{(kb / 1024.0).round}M" if kb >= 1024

      "#{kb}K"
    end

    # --diagnostics: one human-readable line per event, on stderr. stdout
    # belongs to the reporter (`--format json` must stay parseable). `only`
    # limits it to some event types.
    class Text
      def initialize(root:, out: $stderr, only: nil)
        @prefix = "#{root.chomp("/")}/"
        @out = out
        @only = only
      end

      def call(event)
        return if @only && !@only.include?(event.type)

        stamp = "[active_mutator #{event.at.strftime("%H:%M:%S")} +#{format("%.1f", event.elapsed)}s]"
        @out.puts "#{stamp} #{body(event.type, event.fields)}"
      end

      private

      def body(type, fields)
        case type
        when :phase_start, :phase_end then phase(type, fields)
        when :mutant_start then mutant_start(fields)
        when :mutant_end then mutant_end(fields)
        when :memory then memory(fields)
        when :abort then abort(fields)
        when :memory_warning then "warn #{ceiling(fields)}"
        when :memory_ceiling then "#{ceiling(fields)}; stopping the run"
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

      def abort(f)
        running = f[:in_flight].map { |m| "##{m[:seq]} #{m[:subject]} #{m[:file].delete_prefix(@prefix)}:#{m[:line]}" }
        "abort #{f[:reason]}; in flight: #{running.empty? ? "none" : running.join(", ")}"
      end

      # memory at 91% of --max-rss 6.0G (5.5G), or before a coverage parse:
      # memory at 150% of --max-rss 6.0G (9.0G estimated to read a 1.7G coverage.json)
      def ceiling(f)
        percent = (f[:total_pss_kb] * 100.0 / f[:max_rss_kb]).round
        total = Diagnostics.size_kb(f[:total_pss_kb])
        if f[:coverage_bytes]
          total += " estimated to read a #{Diagnostics.size_kb(f[:coverage_bytes] / 1024)} coverage.json"
        end
        "memory at #{percent}% of --max-rss #{Diagnostics.size_kb(f[:max_rss_kb])} (#{total})"
      end

      # mem parent=1.6G workers=4:3.2G baseline=2.1G total=6.9G avail=3.0G swap=0 psi=0.3 load=1.52
      def memory(f)
        parts = ["mem", "parent=#{size(f[:parent])}"]
        parts << "workers=#{f[:workers].size}:#{Diagnostics.size_kb(f[:workers].sum { |w| kb(w) })}" if f[:workers].any?
        parts << "baseline=#{size(f[:baseline])}" if f[:baseline]
        parts << "total=#{Diagnostics.size_kb(f[:total_pss_kb])}"
        parts.concat(system(f[:system])) if f[:system]
        parts.join(" ")
      end

      def system(s)
        parts = ["avail=#{Diagnostics.size_kb(s[:mem_available_kb])}"]
        parts << "swap=#{Diagnostics.size_kb(s[:swap_total_kb] - s[:swap_free_kb])}" if s[:swap_total_kb] && s[:swap_free_kb]
        parts << "psi=#{s[:psi_some_avg10]}" if s[:psi_some_avg10]
        parts << "load=#{s[:load1]}" if s[:load1]
        parts
      end

      # Not endless defs: a one-line method's line runs at
      # load, so coverage can't tie it to the specs that call it.
      def size(reading)
        Diagnostics.size_kb(reading && kb(reading))
      end

      def kb(reading)
        reading[:pss_kb] || reading[:rss_kb]
      end

      def pairs(fields)
        fields.map do |key, value|
          key == :bytes ? "size=#{Diagnostics.size_kb((value / 1024.0).round)}" : "#{key}=#{value}"
        end
      end
    end
  end
end
