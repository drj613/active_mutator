# Runs one operator over every node of a source snippet and returns the
# mutated source strings — golden-test style.
module OperatorHelper
  def mutations_of(source, operator)
    result = Prism.parse(source)
    raise "fixture does not parse: #{source.inspect}" unless result.success?

    edits = []
    each_node(result.value) { |node| edits.concat(operator.edits(node)) }
    edits.map { |e| OpenMutator::Splicer.apply(source, [e]) }
  end

  def each_node(node, &blk)
    yield node
    node.compact_child_nodes.each { |child| each_node(child, &blk) }
  end
end

RSpec.configure { |c| c.include OperatorHelper }
