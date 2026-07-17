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
        # all? is one-way: any? already pairs with none?, so all?→any? adds a
        # distinct mutant without a redundant reverse edge.
        all?: "any?",
        take: "drop", drop: "take",
        min_by: "max_by", max_by: "min_by",
        # sort→reverse is one-way: the reverse (reverse→sort) is near-equivalent
        # on data that is already typically sorted, so we only mutate forward.
        sort: "reverse",
        # detect/find→first is one-way: first ignores the block, so the mutant
        # differs; the reverse (first→detect/find) would be invalid or equivalent.
        detect: "first", find: "first",
        # Evaluated and rejected: sum (initial-arg arity mismatch),
        # find_index (no safe partner — rindex is Array-only).
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
