RSpec.describe "operator re-parse property" do
  def each_node(node, &blk)
    yield node
    node.compact_child_nodes.each { |child| each_node(child, &blk) }
  end

  Dir[File.expand_path("../../lib/**/*.rb", __dir__)].sort.each do |file|
    it "all mutants of #{File.basename(file)} re-parse" do
      source = File.read(file)
      result = Prism.parse(source)
      expect(result.success?).to be(true)

      failures = []
      each_node(result.value) do |node|
        ActiveMutator::Operators::Base.all.each do |operator|
          operator.edits(node).each do |edit|
            mutated = ActiveMutator::Splicer.apply(source, [edit])
            unless Prism.parse(mutated).success?
              failures << "#{operator.class}: #{edit.description} @ bytes #{edit.range}"
            end
          end
        end
      end
      expect(failures).to eq([])
    end
  end
end
