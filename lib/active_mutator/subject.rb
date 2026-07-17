module ActiveMutator
  # A mutable unit: one method definition.
  # byte_range/line_range cover the whole `def ... end`.
  # sclass: def lives inside `class << self` — its source slice is `def foo`,
  # so Inserter must target the singleton class, not the constant itself.
  Subject = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind, :sclass) do
    def initialize(name:, file:, byte_range:, line_range:, constant_scope:, kind:, sclass: false)
      super
    end

    def singleton? = kind == :singleton
  end
end
