RSpec.describe OpenMutator::Runner do
  let(:config) do
    OpenMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: "/project"
    )
  end

  let(:subject_) do
    OpenMutator::Subject.new(name: "A#x", file: "/project/lib/a.rb",
                             byte_range: 0...10, line_range: 1..3,
                             constant_scope: "A", kind: :instance)
  end

  def mutation(line: 2)
    OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: 5...6, replacement: ">=", description: "d"),
      original_snippet: ">", line: line,
      mutated_file_source: "", mutated_def_source: "def x = 1", mutated_def_line: 1
    )
  end

  it "builds work items from covered mutations and reports uncovered ones" do
    covered = mutation(line: 2)
    uncovered = mutation(line: 3)
    map = instance_double(OpenMutator::CoverageMap)
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", 2..2).and_return(["e1"])
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", 3..3).and_return([])
    allow(map).to receive(:time_for).with(["e1"]).and_return(0.5)

    runner = described_class.new(config)
    items, uncovered_results = runner.plan_work([covered, uncovered], map)

    expect(items.size).to eq(1)
    expect(items.first.mutation).to eq(covered)
    expect(items.first.example_ids).to eq(["e1"])
    expect(items.first.timeout).to eq(0.5 * 4.0 + 2.0)
    expect(uncovered_results.map(&:status)).to eq([:uncovered])
  end

  it "exits 1 when mutants survive, 0 otherwise" do
    survived = OpenMutator::Result.new(mutation: mutation, status: :survived, details: nil)
    killed = OpenMutator::Result.new(mutation: mutation, status: :killed, details: nil)
    expect(described_class.new(config).exit_code([killed, survived])).to eq(1)
    expect(described_class.new(config).exit_code([killed])).to eq(0)
  end
end
