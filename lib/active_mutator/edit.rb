module ActiveMutator
  # A single mutation as a text edit: replace `range` (exclusive byte Range)
  # in the original source with `replacement`.
  Edit = Data.define(:range, :replacement, :description)
end
