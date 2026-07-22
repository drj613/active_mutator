require "stringio"

RSpec.describe ActiveMutator::Reporter::Terminal do
  let(:out) { StringIO.new }
  subject(:reporter) { described_class.new(out: out) }

  def mutation(description: "replace `<` with `<=`")
    subject_ = ActiveMutator::Subject.new(
      name: "Calculator#discount", file: "lib/calculator.rb",
      byte_range: 0...1, line_range: 10..13, constant_scope: "Calculator", kind: :instance
    )
    ActiveMutator::Mutation.new(
      subject: subject_,
      edit: ActiveMutator::Edit.new(range: 5...6, replacement: "<=", description: description, operator: "CallSwap"),
      original_snippet: "<", line: 11,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 10
    )
  end

  def result(status)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: nil)
  end

  it "prints one progress char per result" do
    %i[killed survived timeout error uncovered accepted].each { |s| reporter.on_result(result(s)) }
    expect(out.string).to eq(".STEUA")
  end

  it "summarizes counts, score, and survivor diffs" do
    results = [result(:killed), result(:killed), result(:timeout), result(:survived)]
    reporter.summary(results, invalid_count: 2)
    text = out.string
    expect(text).to include("killed: 2", "timeout: 1", "survived: 1", "invalid (discarded): 2")
    expect(text).to include("Mutation score: 75.0%") # (2+1)/(2+1+1)
    expect(text).to include("Calculator#discount", "lib/calculator.rb:11")
    expect(text).to include("replace `<` with `<=`")
    expect(text).to include("- <", "+ <=")
  end

  it "prints the survivor header and entries with blank-line separators" do
    reporter.summary([result(:survived)], invalid_count: 0)
    text = out.string
    expect(text).to include("\n\nSurviving mutants:\n")
    expect(text).to include("\n\n  Calculator#discount (lib/calculator.rb:11)\n")
    expect(text).not_to include("active_mutator")
  end

  it "scores an empty run as 1.0" do
    expect(described_class.score({})).to eq(1.0)
  end

  it "prints per-operator equivalent rates when survivors exist" do
    reporter.summary([result(:survived)], invalid_count: 0)
    expect(out.string).to include("\n\nEquivalent-rate by operator (survived / (killed + survived)):\n")
    expect(out.string).to include("CallSwap")
    expect(out.string).to match(/CallSwap\s+100\.0%\s+\(1 survived \/ 0 killed\)/)
  end

  it "omits the operator table when nothing survived" do
    reporter.summary([result(:killed)], invalid_count: 0)
    expect(out.string).not_to match(/equivalent-rate/i)
  end

  it "reports 100.0% when nothing survives" do
    reporter.summary([result(:killed)], invalid_count: 0)
    expect(out.string).to include("Mutation score: 100.0%")
  end

  def result_with(status, details)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: details)
  end

  it "prints '-' for skipped and lists skip reasons in the summary" do
    skipped = result_with(:skipped, "reload closure (12 constants) exceeds cap (10)")
    reporter.on_result(skipped)
    reporter.summary([skipped], invalid_count: 0)
    expect(out.string).to include("-")
    expect(out.string).to include("skipped: 1")
    expect(out.string).to include("\n\nSkipped mutants (not counted in the score):\n")
    expect(out.string).to include("reload closure (12 constants) exceeds cap (10)")
  end

  it "omits the detail annotation for survivors without details" do
    reporter.summary([result(:survived)], invalid_count: 0)
    expect(out.string).not_to include("    (")
  end

  it "excludes skipped from the mutation score" do
    results = [result(:killed), result_with(:skipped, "x")]
    reporter.summary(results, invalid_count: 0)
    expect(out.string).to include("Mutation score: 100.0%")
  end

  it "shows the escalation annotation on survivors" do
    survivor = result_with(:survived, "escalated (+3 spec files)")
    reporter.summary([survivor], invalid_count: 0)
    expect(out.string).to include("escalated (+3 spec files)")
  end
end
