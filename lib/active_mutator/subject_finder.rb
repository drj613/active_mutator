require "set"

module ActiveMutator
  class SubjectFinder < Prism::Visitor
    SKIP_MARKER = /#\s*active_mutator:\s*skip\b/

    def self.call(file)
      result = Prism.parse(File.read(file))
      return [] unless result.success?

      skip_lines = result.comments
        .select { |c| c.slice.match?(SKIP_MARKER) }
        .to_set { |c| c.location.start_line }
      finder = new(file, skip_lines: skip_lines)
      finder.visit(result.value)
      finder.subjects
    end

    attr_reader :subjects

    def initialize(file, skip_lines: Set.new)
      @file = file
      @skip_lines = skip_lines
      @stack = []
      @subjects = []
      @sclass_depth = 0
      super()
    end

    def visit_class_node(node)
      with_scope(node.constant_path.slice) { super }
    end

    def visit_module_node(node)
      with_scope(node.constant_path.slice) { super }
    end

    # `class << self` inside a constant scope: defs there are singleton
    # methods of the enclosing constant. `class << obj` and a top-level
    # `class << self` (no constant to hang the method on) stay skipped.
    def visit_singleton_class_node(node)
      return unless node.expression.is_a?(Prism::SelfNode) && !@stack.empty?

      @sclass_depth += 1
      begin
        super
      ensure
        @sclass_depth -= 1
      end
    end

    # Defs inside blocks (`Data.define do ... end`, `class_eval do ... end`)
    # do not live on the enclosing constant scope, so Inserter would redefine
    # them on the wrong constant and every mutant would falsely survive.
    # Same v1 limit as `class << self`: not visited. Note this also hides
    # classes/modules defined inside blocks (accepted v1 limit).
    def visit_block_node(node); end

    def visit_def_node(node)
      return if @skip_lines.include?(node.location.start_line - 1)

      sclass = @sclass_depth.positive?
      singleton = sclass || node.receiver.is_a?(Prism::SelfNode)
      scope = @stack.empty? ? nil : @stack.join("::")
      loc = node.location
      @subjects << Subject.new(
        name: "#{scope || "Object"}#{singleton ? "." : "#"}#{node.name}",
        file: @file,
        byte_range: loc.start_offset...loc.end_offset,
        line_range: loc.start_line..loc.end_line,
        constant_scope: scope,
        kind: singleton ? :singleton : :instance,
        sclass: sclass
      )
      # No `super`: nested defs get no subject of their own -- their bodies
      # are mutated via the OUTER def (Engine#walk descends into them).
    end

    private

    def with_scope(name)
      @stack.push(name)
      yield
    ensure
      @stack.pop
    end
  end
end
