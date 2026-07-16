require "json"
require "stringio"

RSpec.describe ActiveMutator::Reporter::Json do
  let(:out) { StringIO.new }
  subject(:reporter) { described_class.new(out: out) }

  it "emits machine-readable results" do
    subject_ = ActiveMutator::Subject.new(
      name: "Calculator#discount", file: "lib/calculator.rb",
      byte_range: 0...1, line_range: 10..13, constant_scope: "Calculator", kind: :instance
    )
    mutation = ActiveMutator::Mutation.new(
      subject: subject_,
      edit: ActiveMutator::Edit.new(range: 5...6, replacement: "<=", description: "replace `<` with `<=`"),
      original_snippet: "<", line: 11,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 10
    )
    result = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
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
      "line" => 11,
      "original" => "<",
      "replacement" => "<=",
      "details" => nil
    )
    expect(data["exit_reason"]).to eq("unaccepted_survivors")
  end

  it "includes per-operator stats in the summary" do
    edit = ActiveMutator::Edit.new(range: 0...1, replacement: "y", description: "d", operator: "CallSwap")
    subject_ = ActiveMutator::Subject.new(name: "Foo#a", file: "foo.rb", byte_range: 0...10,
                                          line_range: 1..2, constant_scope: ["Foo"], kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject_, edit: edit, original_snippet: "x",
                                           line: 1, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    results = [ActiveMutator::Result.new(mutation: mutation, status: :killed, details: nil)]
    reporter.summary(results, invalid_count: 0)
    parsed = JSON.parse(out.string)
    expect(parsed["operators"]).to be_a(Hash)
    expect(parsed["operators"].values).to all(include("killed", "survived", "equivalent_rate"))
  end

  it "reports exit_reason clean when nothing survives" do
    reporter.summary([], invalid_count: 0)
    expect(JSON.parse(out.string)["exit_reason"]).to eq("clean")
  end
end
