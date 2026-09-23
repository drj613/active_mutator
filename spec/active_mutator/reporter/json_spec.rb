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
    expect(data["counts"]).to eq(
      "killed" => 0, "survived" => 1, "timeout" => 0, "error" => 0, "uncovered" => 0, "accepted" => 0, "skipped" => 0
    )
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

  it "emits the normal object with a null score and exit_reason empty_plan for an empty plan" do
    reporter.summary([], invalid_count: 0, empty_plan: true)
    data = JSON.parse(out.string)
    expect(data).to eq(
      "complete" => true,
      "score" => nil,
      "counts" => { "killed" => 0, "survived" => 0, "timeout" => 0, "error" => 0,
                    "uncovered" => 0, "accepted" => 0, "skipped" => 0 },
      "invalid" => 0,
      "operators" => {},
      "results" => [],
      "in_flight" => [],
      "planned" => 0,
      "exit_reason" => "empty_plan"
    )
  end

  describe "an aborted run" do
    let(:in_flight) do
      [{ seq: 3, pid: 42, subject: "Foo#bar", file: "/app/foo.rb", line: 10, description: "replace > with >=" }]
    end

    it "is marked incomplete, with the in-flight mutants, the plan size, and a partial score" do
      results = [result_with(:killed, nil), result_with(:survived, nil)]
      reporter.summary(results, invalid_count: 0, aborted: { reason: :sigterm, in_flight: in_flight, planned: 9 })
      data = JSON.parse(out.string)

      expect(data).to include("complete" => false, "score" => 0.5, "planned" => 9, "exit_reason" => "interrupted")
      expect(data["in_flight"]).to eq([{ "seq" => 3, "pid" => 42, "subject" => "Foo#bar", "file" => "/app/foo.rb",
                                         "line" => 10, "description" => "replace > with >=" }])
      expect(data["results"].size).to eq(2)
    end

    it "reports interrupted for SIGINT and memory_ceiling for the ceiling, with no score when nothing finished" do
      reporter.summary([], invalid_count: 0, aborted: { reason: :sigint, in_flight: [], planned: nil })
      expect(JSON.parse(out.string)).to include("exit_reason" => "interrupted", "score" => nil, "planned" => nil)
      out.truncate(0)
      out.rewind
      reporter.summary([result_with(:survived, nil)], invalid_count: 0,
                       aborted: { reason: :memory_ceiling, in_flight: [], planned: 1 })
      expect(JSON.parse(out.string)).to include("exit_reason" => "memory_ceiling", "score" => 0.0)
    end
  end

  it "reports each mutant's worker seconds and peak memory, and the plan size on a finished run" do
    timed = result_with(:killed, nil).with(seconds: 1.25, peak_rss_kb: 812_000)
    reporter.summary([timed, result_with(:uncovered, nil)], invalid_count: 0)
    data = JSON.parse(out.string)

    expect(data["results"].map { |r| r.slice("seconds", "peak_rss_kb") })
      .to eq([{ "seconds" => 1.25, "peak_rss_kb" => 812_000 }, { "seconds" => nil, "peak_rss_kb" => nil }])
    expect(data).to include("complete" => true, "planned" => 2, "in_flight" => [])
  end

  it "keeps a score and the count-derived exit_reason when empty_plan is false" do
    reporter.summary([], invalid_count: 0, empty_plan: false)
    data = JSON.parse(out.string)
    expect(data["score"]).to eq(1.0)
    expect(data["exit_reason"]).to eq("clean")
  end

  def result_with(status, details)
    subject_ = ActiveMutator::Subject.new(
      name: "Calculator#discount", file: "lib/calculator.rb",
      byte_range: 0...1, line_range: 10..13, constant_scope: "Calculator", kind: :instance
    )
    mutation = ActiveMutator::Mutation.new(
      subject: subject_,
      edit: ActiveMutator::Edit.new(range: 5...6, replacement: "<=", description: "d"),
      original_snippet: "<", line: 11,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 10
    )
    ActiveMutator::Result.new(mutation: mutation, status: status, details: details)
  end

  it "reports exit_reason worker_errors when mutants errored and none survived" do
    reporter.summary([result_with(:error, "boom")], invalid_count: 0)
    data = JSON.parse(out.string)
    expect(data["exit_reason"]).to eq("worker_errors")
    expect(data["score"]).to eq(0.0)
  end

  it "reports exit_reason clean when mutants only timed out (a timeout is a detection)" do
    reporter.summary([result_with(:timeout, "timed out after 1.0s (budget 0.5s)")], invalid_count: 0)
    data = JSON.parse(out.string)
    expect(data["exit_reason"]).to eq("clean")
    expect(data["score"]).to eq(1.0)
  end

  it "ranks survivors over errors in exit_reason" do
    reporter.summary([result_with(:survived, nil), result_with(:error, "boom")], invalid_count: 0)
    expect(JSON.parse(out.string)["exit_reason"]).to eq("unaccepted_survivors")
  end
end
