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

    # Tokens that never change what the code does.
    NOISE = %i[IGNORED_NEWLINE EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END EOF].freeze

    # True when two sources differ only in comments and blank lines. Magic
    # comments (`# frozen_string_literal: true`) change behavior, so they
    # count as code; so does anything that fails to parse.
    def self.same_code?(old_source, new_source)
      old_code = code_of(old_source)
      !old_code.nil? && old_code == code_of(new_source)
    end

    def self.code_of(source)
      result = Prism.parse_lex(source)
      return nil if result.failure?

      # A trailing comment swallows its line's newline, so comments become a
      # newline instead of vanishing; runs of newlines collapse to one.
      tokens = result.value.last.filter_map do |token, _state|
        next if NOISE.include?(token.type)

        %i[COMMENT NEWLINE].include?(token.type) ? :NEWLINE : [token.type, token.value]
      end
      tokens = tokens.chunk_while { |a, b| a == :NEWLINE && b == :NEWLINE }.map(&:first)
      tokens.shift if tokens.first == :NEWLINE
      tokens.pop if tokens.last == :NEWLINE
      [tokens, result.magic_comments.map { |c| [c.key, c.value] }]
    end

    def initialize(ref:, root:)
      @ref = ref
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

    # Whether a changed file's edits since the ref are only comments. Reads
    # the old side with `git show`; a file missing there (untracked, renamed)
    # prints nothing, so it compares against an empty source and any code in
    # it counts.
    def comment_only?(path)
      old_source = IO.popen(["git", "-C", @root, "show", "#{@ref}:#{path}"], err: File::NULL, &:read)
      self.class.same_code?(old_source, File.read(File.join(@root, path)))
    end

    def cover?(subject)
      lines = @changed[subject.file.delete_prefix("#{@root}/")]
      return false unless lines
      return true if lines == :all

      lines.any? { |line| subject.line_range.cover?(line) }
    end
  end
end
