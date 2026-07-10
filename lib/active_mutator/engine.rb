module ActiveMutator
  class Engine
    def initialize(operators: Operators::Base.all)
      @operators = operators
    end

    def analyze(subject, source: File.read(subject.file))
      result = Prism.parse(source)
      raise Error, "#{subject.file} no longer parses" unless result.success?

      def_node = find_def(result.value, subject.byte_range.begin)
      raise Error, "subject not found: #{subject.name}" unless def_node

      invalid = 0
      mutations = collect_edits(def_node).filter_map do |edit|
        mutation, valid = build_mutation(subject, source, edit)
        invalid += 1 unless valid
        mutation
      end
      Analysis.new(mutations: mutations, invalid_count: invalid)
    end

    private

    def find_def(node, start_offset)
      return node if node.is_a?(Prism::DefNode) && node.location.start_offset == start_offset

      node.compact_child_nodes.each do |child|
        found = find_def(child, start_offset)
        return found if found
      end
      nil
    end

    def collect_edits(def_node)
      edits = []
      walk(def_node.body) do |node|
        @operators.each { |op| edits.concat(op.edits(node)) }
      end
      edits
    end

    def walk(node, &blk)
      return if node.nil?
      return if node.is_a?(Prism::DefNode) # nested defs are separate subjects

      yield node
      node.compact_child_nodes.each { |child| walk(child, &blk) }
    end

    # Returns [mutation_or_nil, valid_boolean].
    # valid=true with nil mutation means "skipped no-op", which is not an error.
    def build_mutation(subject, source, edit)
      original = source.byteslice(edit.range)
      return [nil, true] if edit.replacement == original # no-op guard

      mutated = Splicer.apply(source, [edit])
      parsed = Prism.parse(mutated)
      return [nil, false] unless parsed.success?

      new_def = find_def(parsed.value, subject.byte_range.begin)
      return [nil, false] unless new_def

      [Mutation.new(
        subject: subject,
        edit: edit,
        original_snippet: original,
        line: source.byteslice(0, edit.range.begin).count("\n") + 1,
        mutated_file_source: mutated,
        mutated_def_source: new_def.slice,
        mutated_def_line: new_def.location.start_line
      ), true]
    end
  end
end
