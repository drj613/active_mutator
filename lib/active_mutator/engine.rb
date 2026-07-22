module ActiveMutator
  class Engine
    def initialize(operators: Operators::Base.all)
      @operators = operators
    end

    def analyze(subject, source: File.read(subject.file))
      result = Prism.parse(source)
      raise Error, "#{subject.file} no longer parses" unless result.success?

      return analyze_class_body(subject, source, result) if subject.class_body?

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

    def analyze_class_body(subject, source, result)
      class_node = find_class(result.value, subject.byte_range.begin)
      raise Error, "subject not found: #{subject.name}" unless class_node

      invalid = 0
      mutations = collect_class_body_edits(class_node).filter_map do |edit|
        mutation, valid = build_class_body_mutation(subject, source, edit)
        invalid += 1 unless valid
        mutation
      end
      Analysis.new(mutations: mutations, invalid_count: invalid)
    end

    def find_class(node, start_offset)
      if (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)) &&
         node.location.start_offset == start_offset
        return node
      end

      node.compact_child_nodes.each do |child|
        found = find_class(child, start_offset)
        return found if found
      end
      nil
    end

    # Class-level code only: defs, nested class/modules and `class << self`
    # bodies are owned by other subjects. Lambdas (scope bodies, if: procs) ARE
    # descended, as are the ActiveSupport::Concern DSL blocks (`included`,
    # `prepended`, `class_methods`) whose bodies re-run as class-level code in
    # the includer (issue #31). Every OTHER block (association extensions,
    # custom DSLs that run in an unknown context) stays pruned — mutating those
    # risks false survivors. Edits that would delete a whole owned statement
    # (StatementDeletion sees the enclosing StatementsNode) are discarded.
    # Owned ranges are collected recursively while walking, not just from the
    # class body's direct children: a def can nest inside class-level control
    # flow (`if`/`unless`/`begin`), and deleting it there is equally out of
    # scope.
    def collect_class_body_edits(class_node)
      owned = []
      edits = []
      class_walk(class_node.body, owned) do |node|
        @operators.each do |op|
          edits.concat(op.edits(node))
        rescue StandardError => e
          raise Error, "operator #{op.class.name} failed on #{node.class.name}: #{e.message}"
        end
      end
      edits.reject { |e| owned.include?(e.range) }
    end

    def owned_statement?(node) = ClassShape.owned_by_other_subject?(node)

    # ActiveSupport::Concern DSL calls whose block body re-runs as class-level
    # code in the includer, so it is in scope for class-body mutation.
    CONCERN_BLOCK_CALLS = %i[included prepended class_methods].freeze

    def concern_dsl_block?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? &&
        CONCERN_BLOCK_CALLS.include?(node.name) && node.block.is_a?(Prism::BlockNode)
    end

    # No nil guard needed (unlike #walk): the entry node is the class body's
    # StatementsNode, guaranteed present for a class-body subject, and
    # compact_child_nodes never yields nil.
    def class_walk(node, owned, &blk)
      if owned_statement?(node)
        owned << (node.location.start_offset...node.location.end_offset)
        return
      end
      return if node.is_a?(Prism::BlockNode)

      yield node
      if concern_dsl_block?(node)
        # Inside a concern block the statements have no subject of their own, so
        # mutate everything (including nested def bodies) exactly like the
        # def-level #walk — do NOT recurse via class_walk (it would prune the
        # block) and do NOT mark the interior defs owned.
        walk(node.block.body, &blk)
        return
      end
      node.compact_child_nodes.each { |child| class_walk(child, owned, &blk) }
    end

    # The mutant is the whole file. The def-shaped fields are filled with the
    # file source so the Mutation shape stays uniform; Worker routes
    # class-body mutants through ClosureReload (whole-file re-eval), never
    # through Inserter's class_eval.
    def build_class_body_mutation(subject, source, edit)
      original = source.byteslice(edit.range)
      return [nil, true] if edit.replacement == original # no-op guard

      mutated = Splicer.apply(source, [edit])
      parsed = Prism.parse(mutated)
      return [nil, false] unless parsed.success?
      return [nil, false] unless find_class(parsed.value, subject.byte_range.begin)

      [Mutation.new(
        subject: subject,
        edit: edit,
        original_snippet: original,
        line: source.byteslice(0, edit.range.begin).count("\n") + 1,
        mutated_file_source: mutated,
        mutated_def_source: mutated,
        mutated_def_line: 1
      ), true]
    end

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
        @operators.each do |op|
          edits.concat(op.edits(node))
        rescue StandardError => e
          # Fail loud but attributed: a buggy (likely third-party) operator
          # should point at itself, not surface as a bare crash mid-analysis.
          raise Error, "operator #{op.class.name} failed on #{node.class.name}: #{e.message}"
        end
      end
      edits
    end

    def walk(node, &blk)
      return if node.nil?
      # Descend into nested DefNodes rather than treating them as separate
      # subjects. Giving a nested def its own subject identity is a trap:
      # every call of the outer method re-executes the nested `def`, which
      # would silently revert a directly-inserted mutant mid-run (phantom
      # survivors). Instead we mutate the nested body as part of the outer
      # def's re-evaled source. (SubjectFinder still emits no subject for
      # nested defs.) walk is called as walk(def_node.body), so the outer
      # DefNode itself never passes through here.

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
