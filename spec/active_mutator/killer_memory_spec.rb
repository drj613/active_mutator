require "tmpdir"

RSpec.describe ActiveMutator::KillerMemory do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      @path = File.join(dir, ".active_mutator", "killers.json")
      example.run
    end
  end

  let(:example_id) { "./spec/counter_spec.rb[1:1]" }

  def item(name, example_ids: [example_id])
    subject = ActiveMutator::Subject.new(name: name, file: File.join(@root, "lib/counter.rb"),
                                        byte_range: 0...12, line_range: 1..1,
                                        constant_scope: "Counter", kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: nil, original_snippet: "",
                                           line: 1, mutated_file_source: "", mutated_def_source: "", mutated_def_line: 1)
    ActiveMutator::WorkItem.new(mutation: mutation, example_ids: example_ids, timeout: 1, lane: :parallel)
  end

  it "stores project-relative names in the cache directory" do
    memory = described_class.new(@root)
    memory.remember(item("Counter#count"), File.expand_path(example_id, @root))
    memory.save

    expect(JSON.parse(File.read(@path)))
      .to eq(JSON.generate(["lib/counter.rb", "Counter#count", "instance"]) => "spec/counter_spec.rb[1:1]")
  end

  it "prunes stale subjects in an authoritative run, even when it learns nothing new" do
    memory = described_class.new(@root)
    kept, removed = [item("Counter#count"), item("Counter#old")]
    [kept, removed].each { |work| memory.remember(work, example_id) }
    memory.save
    described_class.new(@root).save(subjects: [kept.mutation.subject])

    reloaded = described_class.new(@root)
    expect(reloaded.group_for(kept)).to eq(ActiveMutator::ExampleId.group_key(example_id))
    expect(reloaded.group_for(removed)).to be_nil
  end

  it "ignores a malformed cache and can save verified hints over it" do
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "[1]")
    memory = described_class.new(@root)
    work = item("Counter#count")
    expect(memory.group_for(work)).to be_nil
    memory.remember(work, example_id)
    memory.save
    expect(described_class.new(@root).group_for(work)).to eq(ActiveMutator::ExampleId.group_key(example_id))
  end

  it "does not create a cache file during a cold run with no verified kills" do
    described_class.new(@root).save(subjects: [item("Counter#count").mutation.subject])

    expect(File.exist?(@path)).to be(false)
  end
end
