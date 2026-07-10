module ActiveMutator
  module Operators
    class ConditionForcing < Base
      def edits(node)
        predicate =
          case node
          when Prism::IfNode, Prism::UnlessNode then node.predicate
          end
        return [] unless predicate

        %w[true false].reject { |lit| predicate.slice == lit }.map do |lit|
          edit(loc_range(predicate.location), lit, "force condition to `#{lit}`")
        end
      end
    end
  end
end
