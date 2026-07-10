require "json"
require "stringio"

RSpec.describe OpenMutator::Reporter::Json do
  let(:out) { StringIO.new }
  subject(:reporter) { described_class.new(out: out) }

  it "emits machine-readable results" do
    subject_ = OpenMutator::Subject.new(
      name: "Calculator#discount", file: "lib/calculator.rb",
      byte_range: 0...1, line_range: 10..13, constant_scope: "Calculator", kind: :instance
    )
    mutation = OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: 5...6, replacement: "<=", description: "replace `<` with `<=`"),
      original_snippet: "<", line: 11,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 10
    )
    result = OpenMutator::Result.new(mutation: mutation, status: :survived, details: nil)
    reporter.on_result(result) # must be a no-op, not crash
    reporter.summary([result], invalid_count: 1)

    data = JSON.parse(out.string)
    expect(data["score"]).to eq(0.0)
    expect(data["counts"]).to eq("survived" => 1)
    expect(data["invalid"]).to eq(1)
    expect(data["results"].first).to include(
      "subject" => "Calculator#discount",
      "status" => "survived",
      "description" => "replace `<` with `<=`",
      "file" => "lib/calculator.rb",
      "line" => 11
    )
    expect(data["exit_reason"]).to eq("unaccepted_survivors")
  end

  it "reports exit_reason clean when nothing survives" do
    reporter.summary([], invalid_count: 0)
    expect(JSON.parse(out.string)["exit_reason"]).to eq("clean")
  end
end
