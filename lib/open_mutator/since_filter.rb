module OpenMutator
  # Restricts subjects to methods overlapping lines changed since a git ref.
  # Known v1 limit: `git diff <ref>` omits untracked files, so brand-new
  # uncommitted files are skipped.
  class SinceFilter
    HUNK = /\A@@ [^+]*\+(\d+)(?:,(\d+))? @@/

    def self.parse(diff_text)
      changed = Hash.new { |h, k| h[k] = [] }
      current = nil
      diff_text.each_line do |line|
        if line.start_with?("+++ b/")
          current = line.delete_prefix("+++ b/").strip
        elsif current && (match = HUNK.match(line))
          start = match[1].to_i
          count = (match[2] || "1").to_i
          count.times { |i| changed[current] << start + i }
        end
      end
      changed.reject { |_, lines| lines.empty? }
    end

    def initialize(ref:, root:)
      @root = root
      diff = IO.popen(
        ["git", "-C", root, "diff", "--unified=0", ref, "--", "*.rb"], &:read
      )
      raise Error, "git diff #{ref} failed" unless $?.success?

      @changed = self.class.parse(diff)
    end

    def cover?(subject)
      lines = @changed[subject.file.delete_prefix("#{@root}/")]
      return false unless lines

      lines.any? { |line| subject.line_range.cover?(line) }
    end
  end
end
