module ActiveMutator
  module Operators
    class StatementDeletion < Base
      def edits(node)
        return [] unless node.is_a?(Prism::StatementsNode)
        return [] if node.body.size < 2

        node.body.map do |stmt|
          edit(loc_range(stmt.location), "",
               "delete `#{stmt.slice.lines.first.strip}`")
        end
      end
    end
  end
end
