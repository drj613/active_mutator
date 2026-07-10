module OpenMutator
  module Operators
    class Base
      REGISTRY = []

      def self.inherited(klass)
        super
        REGISTRY << klass
      end

      def self.all = REGISTRY.map(&:new)

      # Returns [Edit] for this node, or [] when the operator does not apply.
      def edits(node) = []

      private

      def loc_range(loc) = loc.start_offset...loc.end_offset

      def edit(range, replacement, description)
        Edit.new(range: range, replacement: replacement, description: description)
      end
    end
  end
end
