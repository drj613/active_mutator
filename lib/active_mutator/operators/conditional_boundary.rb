module ActiveMutator
  module Operators
    class ConditionalBoundary < Base
      MAP = { :> => ">=", :>= => ">", :< => "<=", :<= => "<" }.freeze

      def edits(node)
        return [] unless node.is_a?(Prism::CallNode) && MAP.key?(node.name)
        return [] unless node.receiver && node.arguments&.arguments&.size == 1

        replacement = MAP.fetch(node.name)
        [edit(loc_range(node.message_loc), replacement,
              "replace `#{node.name}` with `#{replacement}`")]
      end
    end
  end
end
