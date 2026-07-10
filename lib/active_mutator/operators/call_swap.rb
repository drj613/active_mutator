module ActiveMutator
  module Operators
    class CallSwap < Base
      # One-directional where the reverse is usually an equivalent mutant
      # (e.g. each→map when return value is unused).
      MAP = {
        map: "each",
        select: "reject", reject: "select",
        min: "max", max: "min",
        first: "last", last: "first",
        any?: "none?", none?: "any?",
        # Rails-aware pack:
        present?: "blank?", blank?: "present?",
        save: "save!", save!: "save"
      }.freeze

      def edits(node)
        return [] unless node.is_a?(Prism::CallNode) && node.receiver && node.message_loc

        replacement = MAP[node.name]
        return [] unless replacement

        [edit(loc_range(node.message_loc), replacement,
              "replace `.#{node.name}` with `.#{replacement}`")]
      end
    end
  end
end
