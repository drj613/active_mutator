module OpenMutator
  class SubjectFinder < Prism::Visitor
    def self.call(file)
      result = Prism.parse(File.read(file))
      return [] unless result.success?

      finder = new(file)
      finder.visit(result.value)
      finder.subjects
    end

    attr_reader :subjects

    def initialize(file)
      @file = file
      @stack = []
      @subjects = []
      super()
    end

    def visit_class_node(node)
      with_scope(node.constant_path.slice) { super }
    end

    def visit_module_node(node)
      with_scope(node.constant_path.slice) { super }
    end

    # `class << self` bodies are a documented v1 limit: not visited.
    def visit_singleton_class_node(node); end

    def visit_def_node(node)
      singleton = node.receiver.is_a?(Prism::SelfNode)
      scope = @stack.empty? ? nil : @stack.join("::")
      loc = node.location
      @subjects << Subject.new(
        name: "#{scope || "Object"}#{singleton ? "." : "#"}#{node.name}",
        file: @file,
        byte_range: loc.start_offset...loc.end_offset,
        line_range: loc.start_line..loc.end_line,
        constant_scope: scope,
        kind: singleton ? :singleton : :instance
      )
      # No `super`: nested defs are out of scope for v1.
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
