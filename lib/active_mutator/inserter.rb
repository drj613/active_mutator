module ActiveMutator
  # Redefines the subject's method with its mutated source. `class_eval` of a
  # `def` handles instance methods; a `def self.x` source string defines the
  # singleton method the same way. Top-level subjects eval at main scope.
  class Inserter
    def insert(mutation)
      subject = mutation.subject
      if subject.constant_scope
        Object.const_get(subject.constant_scope)
              .class_eval(mutation.mutated_def_source, subject.file, mutation.mutated_def_line)
      else
        eval(mutation.mutated_def_source, TOPLEVEL_BINDING, # rubocop:disable Security/Eval
             subject.file, mutation.mutated_def_line)
      end
      nil
    end
  end
end
