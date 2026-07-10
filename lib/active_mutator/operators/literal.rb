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
        return [] unless opening                  # quote-less parts (interpolation)
        return [] if opening.start_with?("<<")    # heredocs: v1 limit

        if node.unescaped.empty?
          [edit(loc_range(node.location), %("active_mutator"), %(replace "" with "active_mutator"))]
        else
          [edit(loc_range(node.location), %(""), %(replace string with ""))]
        end
      end
    end
  end
end
