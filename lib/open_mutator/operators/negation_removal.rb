module OpenMutator
  module Operators
    class NegationRemoval < Base
      def edits(node)
        return [] unless node.is_a?(Prism::CallNode) && node.name == :! && node.receiver

        [edit(loc_range(node.location), node.receiver.slice, "remove negation")]
      end
    end
  end
end
