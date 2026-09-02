module ActiveMutator
  # A mutable unit. kind :instance/:singleton = one method definition
  # (byte_range/line_range cover the whole `def ... end`). kind :class_body =
  # the class-level code of one class/module (byte_range covers the whole
  # class/module node; Engine only mutates non-def body statements).
  # sclass: def lives inside `class << self` — its source slice is `def foo`,
  # so Inserter must target the singleton class, not the constant itself.
  # reload: def lives inside a concern's `included`/`prepended` block, so it
  # lands on the includer, not on the constant; the only faithful insertion is
  # the same whole-file closure reload a class-body mutant gets.
  Subject = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind, :sclass, :reload) do
    def initialize(name:, file:, byte_range:, line_range:, constant_scope:, kind:, sclass: false, reload: false)
      super
    end

    def singleton? = kind == :singleton

    def class_body? = kind == :class_body

    def reload? = class_body? || reload
  end
end
