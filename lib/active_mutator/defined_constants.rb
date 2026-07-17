require "prism"

module ActiveMutator
  # Deepest fully qualified names of classes/modules a source file defines
  # ("Billing::Invoice"). Two shorthands are deliberately never emitted,
  # because either would let a single common token match half of any real
  # spec suite and trip BaselineDelta's full-run fallback on every edit:
  #   - bare leaves ("Config" for MyApp::Config)
  #   - pure namespace wrappers ("MyApp" for `module MyApp; class Config`):
  #     every file in a namespaced app reopens the top module, and every
  #     spec mentions it.
  # A wrapper is a node whose non-empty direct body contains ONLY nested
  # class/module definitions. A module with its own defs/macros/constants is
  # a real edit target and IS emitted; so is an empty or def-less leaf class
  # (macro-only ActiveRecord models).
  #
  # Guard is errors.any?, not warnings: Prism produces a complete AST for
  # warnings-only input (`if a = 2`), and those definitions are real.
  module DefinedConstants
    def self.in_source(source)
      result = Prism.parse(source)
      return [] if result.errors.any?

      names = []
      walk(result.value, [], names)
      names.uniq
    end

    def self.walk(node, scope, names)
      if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        scope = scope + [node.constant_path.slice]
        names << scope.join("::") unless namespace_wrapper?(node)
      end
      node.compact_child_nodes.each { |child| walk(child, scope, names) }
    end
    private_class_method :walk

    def self.namespace_wrapper?(node)
      statements = node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
      statements.any? &&
        statements.all? { |s| s.is_a?(Prism::ClassNode) || s.is_a?(Prism::ModuleNode) }
    end
    private_class_method :namespace_wrapper?
  end
end
