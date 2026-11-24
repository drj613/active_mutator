require "tmpdir"

RSpec.describe ActiveMutator::VerdictStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      @file = File.join(dir, "lib/counter.rb")
      @path = File.join(dir, ".active_mutator", "verdicts.json")
      example.run
    end
  end

  let(:config) { instance_double(ActiveMutator::Config, root: @root) }
  let(:spec_digests) { { "spec/counter_spec.rb" => "spec digest" } }
  let(:map) { ActiveMutator::CoverageMap.new("records" => {}) }

  def store(setup: "setup digest", specs: spec_digests)
    inputs = instance_double(ActiveMutator::RunInputs, setup: setup,
                             source_digests: { @file => "source digest" })
    allow(inputs).to receive(:spec_digests).with(map).and_return(specs)
    described_class.new(config, map, inputs: inputs)
  end

  def item(replacement = "0")
    subject = ActiveMutator::Subject.new(name: "Counter#count", file: @file, byte_range: 0...12,
                                        line_range: 1..1, constant_scope: "Counter", kind: :instance)
    edit = ActiveMutator::Edit.new(range: 10...11, replacement: replacement, description: "replace count")
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: "2", line: 1,
                                          mutated_file_source: "", mutated_def_source: "", mutated_def_line: 1)
    ActiveMutator::WorkItem.new(mutation: mutation, example_ids: ["./spec/counter_spec.rb[1:1]"],
                                timeout: 5, lane: :parallel)
  end

  def result(item, status)
    ActiveMutator::Result.new(mutation: item.mutation, status: status, details: nil)
  end

  def seed(item)
    cache = store
    cache.partition([item])
    cache.save([result(item, :killed)], prune: false)
  end

  it "ignores results from a different setup" do
    work = item
    seed(work)

    expect(store(setup: "changed setup").partition([work])).to eq([[work], []])
  end

  it "reruns a mutant with a malformed entry or an unknown spec digest" do
    work = item
    seed(work)
    expect(store(specs: {}).partition([work])).to eq([[work], []])

    data = JSON.parse(File.read(@path))
    data.fetch("entries").each_value { |entry| entry["ignored"] = nil }
    File.write(@path, JSON.generate(data))
    expect(store.partition([work])).to eq([[work], []])
  end

  it "removes inconclusive verdicts instead of carrying them again" do
    timed_out, errored, inconclusive, skipped = %w[0 1 3 4].map { |value| item(value) }
    work = [timed_out, errored, inconclusive, skipped]
    work.each { |entry| seed(entry) }
    cache = store
    cache.partition(work)
    cache.discard(inconclusive.mutation)
    cache.save([result(timed_out, :timeout), result(errored, :error), result(inconclusive, :survived),
                result(skipped, :skipped)], prune: false)

    expect(store.partition(work)).to eq([work, []])
  end

  it "merges results from overlapping scoped runs" do
    first, second = store, store
    left, right = item("0"), item("3")
    first.partition([left])
    second.partition([right])
    first.save([result(left, :killed)], prune: false)
    second.save([result(right, :survived)], prune: false)

    pending, carried = store.partition([left, right])
    expect(pending).to be_empty
    expect(carried.map(&:status)).to eq(%i[killed survived])
  end
end
