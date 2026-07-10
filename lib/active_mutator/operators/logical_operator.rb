module ActiveMutator
  module Operators
    class LogicalOperator < Base
      def edits(node)
        case node
        when Prism::AndNode then variants(node, "||")
        when Prism::OrNode then variants(node, "&&")
        else []
        end
      end

      private

      def variants(node, swapped)
        [
          edit(loc_range(node.operator_loc), swapped,
               "replace `#{node.operator_loc.slice}` with `#{swapped}`"),
          edit(loc_range(node.location), node.left.slice, "keep only left operand"),
          edit(loc_range(node.location), node.right.slice, "keep only right operand")
        ]
      end
    end
  end
end
