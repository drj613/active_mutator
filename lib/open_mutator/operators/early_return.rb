module OpenMutator
  module Operators
    class EarlyReturn < Base
      def edits(node)
        return [] unless node.is_a?(Prism::ReturnNode) && node.arguments

        value = node.arguments.slice
        out = [edit(loc_range(node.location), value, "unwrap `return`")]
        unless value == "nil"
          out << edit(loc_range(node.location), "return nil", "return nil instead")
        end
        out
      end
    end
  end
end
