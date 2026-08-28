module ActiveMutator
  module Operators
    class StatementDeletion < Base
      def edits(node)
        return [] unless node.is_a?(Prism::StatementsNode)
        return [] if node.body.size < 2

        # A heredoc's body lives on the lines after the statement, outside the
        # node's byte range, so deleting the range leaves the body behind as
        # unparseable text. Skip those statements.
        node.body.reject { |stmt| contains_heredoc?(stmt) }.map do |stmt|
          edit(loc_range(stmt.location), "",
               "delete `#{stmt.slice.lines.first.strip}`")
        end
      end

      private

      def contains_heredoc?(node)
        return true if node.respond_to?(:heredoc?) && node.heredoc?

        node.compact_child_nodes.any? { |child| contains_heredoc?(child) }
      end
    end
  end
end
