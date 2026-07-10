module ActiveMutator
  module Splicer
    # Applies edits to source by byte offset. Edits are applied back-to-front
    # so earlier offsets never drift.
    def self.apply(source, edits)
      bytes = source.b
      edits.sort_by { |e| -e.range.begin }.each do |e|
        bytes[e.range] = e.replacement.b
      end
      bytes.force_encoding(source.encoding)
    end
  end
end
