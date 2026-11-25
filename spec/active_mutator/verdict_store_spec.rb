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

  def store(setup: "setup digest", specs: spec_digests, sources: { @file => "source digest" }, coverage: map)
    inputs = instance_double(ActiveMutator::RunInputs, setup: setup,
                             source_digests: sources)
    allow(inputs).to receive(:spec_digests).with(coverage).and_return(specs)
    described_class.new(config, coverage, inputs: inputs)
  end

  def item(replacement = "0", kind: :instance, ids: ["./spec/counter_spec.rb[1:1]"])
    subject = ActiveMutator::Subject.new(name: "Counter#count", file: @file, byte_range: 0...12,
                                        line_range: 1..1, constant_scope: "Counter", kind: kind)
    edit = ActiveMutator::Edit.new(range: 10...11, replacement: replacement, description: "replace count")
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: "2", line: 1,
                                          mutated_file_source: "", mutated_def_source: "", mutated_def_line: 1)
    ActiveMutator::WorkItem.new(mutation: mutation, example_ids: ids,
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

  it "keeps cache parsing and signatures private" do
    expect(store).not_to respond_to(:read_entries)
    expect(store).not_to respond_to(:identity_and_signature)
  end

  it "rejects an entry claiming a missing signature" do
    work = item
    seed(work)
    data = JSON.parse(File.read(@path))
    data.fetch("entries").each_value { |entry| entry["signature"] = nil }
    File.write(@path, JSON.generate(data))

    expect(store(specs: {}).partition([work])).to eq([[work], []])
  end

  it "does not write verdicts for source files outside the planning snapshot" do
    work = item
    seed(work)
    cache = store(sources: {})
    cache.partition([work])
    cache.save([result(work, :killed)], prune: false)
    expect(JSON.parse(File.read(@path)).fetch("entries")).to be_empty
  end

  it "carries a method mutant when an unrelated spec changes" do
    work = item
    seed(work)
    unrelated = ActiveMutator::CoverageMap.new("records" => { "./spec/other_spec.rb[1:1]" => [] })
    changed = spec_digests.merge("spec/other_spec.rb" => "changed")
    expect(store(specs: changed, coverage: unrelated).partition([work]).last.map(&:status)).to eq([:killed])
  end

  it "writes version 2 verdicts and rejects an older schema" do
    work = item
    seed(work)
    data = JSON.parse(File.read(@path))
    expect(data.fetch("schema")).to eq(2)

    File.write(@path, JSON.generate(data.merge("schema" => 1)))
    expect(store.partition([work])).to eq([[work], []])
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

  [
    ["status", "timeout"],
    ["killed_by", nil],
    ["killed_by", [42]],
    ["passed", []],
    ["passed", { "./spec/counter_spec.rb[1:1]" => 42 }],
    ["ignored", [42]]
  ].each do |field, invalid|
    it "reruns a mutant when its stored #{field} is #{invalid.inspect}" do
      work = item
      seed(work)
      data = JSON.parse(File.read(@path))
      data.fetch("entries").each_value { |entry| entry[field] = invalid }
      File.write(@path, JSON.generate(data))

      expect(store.partition([work])).to eq([[work], []])
    end
  end

  it "ignores a cache with a malformed envelope" do
    work = item
    seed(work)
    data = JSON.parse(File.read(@path))
    [42, data.merge("entries" => nil)].each do |invalid|
      File.write(@path, JSON.generate(invalid))
      expect(store.partition([work])).to eq([[work], []])
    end
  end

  it "only carries a verdict for the same source digest and covering set" do
    work = item
    seed(work)
    expect(store(sources: { @file => "changed" }).partition([work])).to eq([[work], []])
    expect(store(sources: {}).partition([work])).to eq([[work], []])
    different = item(ids: ["./spec/counter_spec.rb[1:2]"])
    expect(store.partition([different])).to eq([[different], []])
  end

  it "requires every covering spec digest and ignores the order of covering IDs" do
    ids = ["./spec/counter_spec.rb[1:1]", "./spec/other_spec.rb[1:1]"]
    work = item(ids: ids)
    specs = spec_digests.merge("spec/other_spec.rb" => "other digest")
    cache = store(specs: specs)
    cache.partition([work])
    cache.save([result(work, :killed)], prune: false)

    reversed = item(ids: ids.reverse)
    expect(store(specs: specs).partition([reversed]).last.map(&:status)).to eq([:killed])
    expect(store.partition([work])).to eq([[work], []])
    incomplete = store
    incomplete.partition([work])
    incomplete.save([result(work, :killed)], prune: false)
    expect(JSON.parse(File.read(@path)).fetch("entries")).to be_empty
    expect(store.partition([work])).to eq([[work], []])
  end

  it "invalidates only the method verdicts whose examples executed changed dependency files" do
    a, b = %w[./spec/counter_spec.rb[1:1] ./spec/counter_spec.rb[1:2]]
    left, right = item(ids: [a]), item("3", ids: [b])
    records = { a => [[File.join(@root, "lib/limits.rb"), 2]], b => [[@file, 2]] }
    digests = { "lib/limits.rb" => "previous", "lib/counter.rb" => "source digest" }
    first = ActiveMutator::CoverageMap.new("records" => records, "digests" => digests)
    cache = store(coverage: first)
    cache.partition([left, right])
    cache.save([result(left, :killed), result(right, :killed)], prune: false)

    changed = ActiveMutator::CoverageMap.new("records" => records, "digests" => digests.merge("lib/limits.rb" => "new"))
    expect(store(coverage: changed).partition([left, right])).to eq([[left], [result(right, :killed).with(carried: true)]])
  end

  it "checks all candidate spec digests and example IDs for class-body verdicts" do
    work = item(kind: :class_body)
    other = "./spec/other_spec.rb[1:1]"
    another = "./spec/another_spec.rb[1:1]"
    records = { other => [], another => [] }
    specs = spec_digests.merge("spec/other_spec.rb" => "other digest", "spec/another_spec.rb" => "another digest")
    cached = store(specs: specs, coverage: ActiveMutator::CoverageMap.new("records" => records))
    cached.partition([work])
    cached.save([result(work, :survived)], prune: false)

    reordered = ActiveMutator::CoverageMap.new("records" => records.to_a.reverse.to_h)
    expect(store(specs: specs.to_a.reverse.to_h, coverage: reordered).partition([work]).last.map(&:status))
      .to eq([:survived])
    expect(store(specs: specs, coverage: ActiveMutator::CoverageMap.new("records" => { another => [] }))
            .partition([work])).to eq([[work], []])
    expect(store(specs: specs.merge("spec/other_spec.rb" => "changed"), coverage: reordered).partition([work]))
      .to eq([[work], []])
  end

  it "round-trips audit evidence and details with carried kills" do
    work = item
    cache = store
    cache.partition([work])
    fresh = result(work, :killed).with(details: "worker detail", killed_by: ["./spec/counter_spec.rb[1:1]"],
                                       passed: { "./spec/counter_spec.rb[1:2]" => "./spec/counter_spec.rb:5" },
                                       ignored: ["./spec/counter_spec.rb[1:3]"])
    cache.save([fresh], prune: false)

    expect(store.partition([work])).to eq([[], [fresh.with(carried: true)]])
  end

  it "prunes entries only when the plan is authoritative" do
    left, right = item("0"), item("3")
    seed(left)
    seed(right)
    cache = store
    cache.partition([left])
    cache.save([result(left, :killed), result(item("4"), :uncovered)], prune: true)

    expect(store.partition([left, right]).first).to eq([right])
    expect(JSON.parse(File.read(@path)).fetch("entries").size).to eq(1)
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

    expect(JSON.parse(File.read(@path)).fetch("entries")).to be_empty
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
