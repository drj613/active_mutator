module ActiveMutator
  module Operators
    class Literal < Base
      def edits(node)
        case node
        when Prism::IntegerNode then integer_edits(node)
        when Prism::StringNode then string_edits(node)
        when Prism::TrueNode
          [edit(loc_range(node.location), "false", "replace `true` with `false`")]
        when Prism::FalseNode
          [edit(loc_range(node.location), "true", "replace `false` with `true`")]
        else []
        end
      end

      private

      def integer_edits(node)
        [0, node.value + 1].uniq.reject { |v| v == node.value }.map do |v|
          edit(loc_range(node.location), v.to_s, "replace `#{node.value}` with `#{v}`")
        end
      end

      def string_edits(node)
        opening = node.opening_loc&.slice
        return [] unless opening                # quote-less parts (interpolation)
        return heredoc_edits(node) if opening.start_with?("<<")

        if node.unescaped.empty?
          [edit(loc_range(node.location), %("active_mutator"), %(replace "" with "active_mutator"))]
        else
          [edit(loc_range(node.location), %(""), %(replace string with ""))]
        end
      end

      # The node span covers the `<<~X` opening token; splicing there breaks
      # the source. Mutate the body content range instead: nonempty body →
      # empty heredoc (opening line directly followed by the terminator).
      # The guard is on the DEDENTED VALUE (unescaped), not content_loc: a
      # squiggly body that dedents to "" would only lose whitespace bytes —
      # an equivalent mutant — so it is skipped even though content is nonempty.
      def heredoc_edits(node)
        return [] if node.unescaped.empty?

        [edit(loc_range(node.content_loc), "", "empty heredoc body")]
      end
    end
  end
end
