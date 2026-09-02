# Dependency-free stand-in for ActiveSupport::Concern's `included do ... end`:
# the block is stored and replayed (class_eval'd) into each includer at include
# time via append_features — the same mechanism ActiveSupport uses. Lets the
# fixture exercise concern-block mutation without pulling Rails into the bundle.
module MiniConcern
  # `included` is also Ruby's include-hook (Module#included(base)). Like
  # ActiveSupport::Concern, disambiguate: no argument means the DSL form
  # (`included do ... end`) and stores the block; a base argument means the
  # hook firing, which we let default through.
  def included(base = nil, &block)
    return super(base) unless base.nil?

    (@included_blocks ||= []) << block
  end

  # Mirrors ActiveSupport::Concern#class_methods: the block is module_eval'd
  # into a real `ClassMethods` constant that the includer then extends.
  def class_methods(&block)
    mod = const_defined?(:ClassMethods, false) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)
    mod.module_eval(&block)
  end

  def append_features(base)
    super
    base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods, false)
    (@included_blocks ||= []).each { |b| base.class_eval(&b) }
  end
end
