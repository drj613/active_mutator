module ActiveMutator
  # 1-based line/column (never 0 — the Stryker schema rejects 0) for an
  # exclusive byte range within a source string.
  module SourceLocation
    def self.locate(source, byte_range)
      {
        start: position(source, byte_range.begin),
        end: position(source, byte_range.end)
      }
    end

    def self.position(source, offset)
      prefix = source.byteslice(0, offset)
      last_newline = prefix.rindex("\n")
      {
        line: prefix.count("\n") + 1,
        column: offset - (last_newline ? last_newline + 1 : 0) + 1
      }
    end
  end
end
