module ActiveMutator
  # A mutable unit. kind :instance/:singleton = one method definition
  # (byte_range/line_range cover the whole `def ... end`). kind :class_body =
  # the class-level code of one class/module (byte_range covers the whole
  # class/module node; Engine only mutates non-def body statements).
  # sclass: def lives inside `class << self` — its source slice is `def foo`,
  # so Inserter must target the singleton class, not the constant itself.
  Subject = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind, :sclass) do
    def initialize(name:, file:, byte_range:, line_range:, constant_scope:, kind:, sclass: false)
      super
    end

    def singleton? = kind == :singleton

    def class_body? = kind == :class_body
  end
end
