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
        # sort→reverse is one-way by design: reverse already has a strong
        # forward mutant here, and reverse→sort would double-map `reverse`
        # against nothing useful (reverse has no MAP entry to preserve).
        sort: "reverse",
        # detect/find→first is one-way: first ignores the retained block, so
        # the mutant usually differs (equivalent only when element 0 already
        # satisfies the predicate). No reverse edge: `first` is taken by
        # first→last above.
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
