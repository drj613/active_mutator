require_relative "mini_concern"

# A concern whose class-level code lives in an `included do ... end` block (the
# ActiveSupport::Concern idiom). A mutation INSIDE the block must still be
# killable end-to-end, which requires closure reload to re-run the mutated block
# in the includer.
module Trackable
  extend MiniConcern

  included do
    # Multi-line body on purpose: the string lives on its own line, which is
    # only executed when tracking_label is CALLED from an example (not at
    # include/load time), so per-example coverage attributes it to the spec
    # that exercises it — the mutant is covered, not uncovered.
    def tracking_label
      "tracked"
    end
  end
end
