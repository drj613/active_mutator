module ActiveMutator
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

    # Every file the diff touched on the new side, including deletion-only
    # files that `parse` drops (they add no lines, so nothing to cover, but
    # the file still changed and must count as a --since candidate).
    def self.touched_files(diff_text)
      diff_text.each_line.filter_map do |line|
        line.delete_prefix("+++ b/").strip if line.start_with?("+++ b/")
      end.uniq
    end

    def initialize(ref:, root:)
      @root = root
      diff = IO.popen(
        ["git", "-C", root, "diff", "--unified=0", ref, "--", "*.rb"], &:read
      )
      raise Error, "git diff #{ref} failed" unless $?.success?

      @changed = self.class.parse(diff)
      @touched = self.class.touched_files(diff)
      untracked = IO.popen(
        ["git", "-C", root, "ls-files", "--others", "--exclude-standard", "--", "*.rb"], &:read
      )
      # Untracked files are invisible to `git diff` but are agentic TDD's most
      # common case (brand-new file + spec). Whole-file sentinel: every line
      # counts as changed.
      untracked.split("\n").each { |l| @changed[l] = :all }
      @touched |= @changed.keys
    end

    # Root-relative paths of every .rb file the diff touched (tracked files,
    # including deletion-only ones, plus untracked files). Pure accessor: no
    # further git calls.
    def changed_files = @touched

    def cover?(subject)
      lines = @changed[subject.file.delete_prefix("#{@root}/")]
      return false unless lines
      return true if lines == :all

      lines.any? { |line| subject.line_range.cover?(line) }
    end
  end
end
