module ActiveMutator
  # A single mutation as a text edit: replace `range` (exclusive byte Range)
  # in the original source with `replacement`. `operator` is the producing
  # operator's demodulized class name ("CallSwap"), "Unknown" outside the
  # operator pipeline.
  Edit = Data.define(:range, :replacement, :description, :operator) do
    def initialize(range:, replacement:, description:, operator: "Unknown")
      super
    end
  end
end
