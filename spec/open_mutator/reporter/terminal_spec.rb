require "stringio"

RSpec.describe OpenMutator::Reporter::Terminal do
  let(:out) { StringIO.new }
  subject(:reporter) { described_class.new(out: out) }

  def mutation(description: "replace `<` with `<=`")
    subject_ = OpenMutator::Subject.new(
      name: "Calculator#discount", file: "lib/calculator.rb",
      byte_range: 0...1, line_range: 10..13, constant_scope: "Calculator", kind: :instance
    )
    OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: 5...6, replacement: "<=", description: description),
      original_snippet: "<", line: 11,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 10
    )
  end

  def result(status)
    OpenMutator::Result.new(mutation: mutation, status: status, details: nil)
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

  it "reports 100.0% when nothing survives" do
    reporter.summary([result(:killed)], invalid_count: 0)
    expect(out.string).to include("Mutation score: 100.0%")
  end
end
