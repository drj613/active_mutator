module ActiveMutator
  # Structural predicates over a parsed file that the class-level machinery
  # must apply IDENTICALLY in more than one place. Centralized so the gates
  # cannot drift:
  #   - SubjectFinder decides which files get a class-body subject.
  #   - ClosureReload decides which dependent files are safe to remove_const
  #     and re-eval.
  # Both need the same "is this file a single reloadable constant?" rule, and
  # both need the same "does this class-body statement belong to another
  # subject?" rule.
  # `extend self`, not `module_function`: module_function copies each method
  # onto the singleton at definition time, so a def-level mutant (which
  # redefines the INSTANCE method in the fork) would never reach the singleton
  # copy that callers invoke — an untestable false survivor. `extend self`
  # keeps ONE method object, dispatched to via the singleton's ancestry.
  module ClassShape
    extend self

    # Zeitwerk-shaped: the file defines exactly one top-level constant, so
    # remove_const + whole-file re-eval reinstates precisely that constant
    # (issue #32). A file with more than one would re-run macros on / reassign
    # the constants that were NOT removed (accumulation and "already
    # initialized constant" bugs).
    #
    # Counts every top-level constant-DEFINING form, not just `class`/`module`
    # blocks: `Adapter = Class.new`, `Point = Struct.new(...)`,
    # `Config = Data.define(...)`, and plain `CONST = ...` are ConstantWriteNodes
    # (or ConstantPathWriteNodes) that a class/module-only count missed, letting
    # a two-constant file slip through and get reassigned on re-eval.
    def single_top_level_constant?(program)
      program.statements.body.count { |s| defines_constant?(s) } == 1
    end

    def defines_constant?(node)
      node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ||
        node.is_a?(Prism::ConstantWriteNode) || node.is_a?(Prism::ConstantPathWriteNode)
    end

    # A class-body statement that is owned by a DIFFERENT subject — its own
    # def, or a nested class/module/singleton-class that gets its own subjects.
    # The class-body walk must neither collect edits for it nor delete it.
    def owned_by_other_subject?(node)
      node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) ||
        node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)
    end
  end
end
