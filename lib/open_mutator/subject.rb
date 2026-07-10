module OpenMutator
  # A mutable unit: one method definition.
  # byte_range/line_range cover the whole `def ... end`.
  Subject = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind) do
    def singleton? = kind == :singleton
  end
end
