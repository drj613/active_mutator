require "spec_helper"

RSpec.describe ActiveMutator::Reporter::Github do
  def build_result(status, description: "replace `>` with `>=`", snippet: "x > 0", replacement: "x >= 0")
    edit = ActiveMutator::Edit.new(range: 13...18, replacement: replacement,
                                   description: description, operator: "ConditionalBoundary")
    subject = ActiveMutator::Subject.new(name: "Calc#pos", file: "/repo/lib/calc.rb", byte_range: 0...20,
                                         line_range: 1..3, constant_scope: ["Calc"], kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: snippet,
                                           line: 2, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: nil)
  end

  let(:out) { StringIO.new }
  let(:reporter) { described_class.new(root: "/repo", out: out) }

  it "emits one ::warning line per survivor with root-relative path" do
    reporter.summary([build_result(:survived), build_result(:killed)], invalid_count: 0)
    warnings = out.string.lines.select { |l| l.start_with?("::warning") }
    expect(warnings.length).to eq(1)
    expect(warnings.first).to start_with("::warning file=lib/calc.rb,line=2,title=Surviving mutant::")
    expect(warnings.first).to include("Calc#pos")
    expect(warnings.first).to include("replace `>` with `>=`")
  end

  it "formats the message as a multi-line diff with a plain-English hint" do
    reporter.summary([build_result(:survived)], invalid_count: 0)
    warning = out.string.lines.find { |l| l.start_with?("::warning") }
    expect(warning).to include(
      "Calc#pos: replace `>` with `>=`%0A- x > 0%0A+ x >= 0%0AEvery test still passed"
    )
  end

  describe "an aborted run" do
    let(:in_flight) do
      [{ seq: 7, pid: 1, subject: "Calc#neg", file: "/repo/lib/calc.rb", line: 9, description: "d1" },
       { seq: 8, pid: 2, subject: "Calc#abs", file: "/repo/lib/calc.rb", line: 12, description: "d2" }]
    end

    it "prints the terminal's partial summary, the finished survivors, then one ::error for the abort" do
      reporter.summary([build_result(:survived), build_result(:killed)], invalid_count: 0,
                       aborted: { reason: :sigterm, in_flight: in_flight, planned: 10 })
      lines = out.string.lines

      expect(out.string).to include("Run aborted (SIGTERM): partial results")
      expect(lines[-2]).to start_with("::warning") # the finished survivor
      expect(lines.last).to eq(
        "::error title=Mutation run aborted::The run stopped early (SIGTERM), so this is not a full result.%0A" \
        "In flight: #7 Calc#neg (/repo/lib/calc.rb:9) d1; #8 Calc#abs (/repo/lib/calc.rb:12) d2%0A" \
        "Partial mutation score: 50.0%25 (2 of 10 mutants)\n"
      )
    end

    it "leaves out the in-flight line when nothing was running" do
      reporter.summary([], invalid_count: 0, aborted: { reason: :memory_ceiling, in_flight: [], planned: nil })
      expect(out.string.lines.last).to eq(
        "::error title=Mutation run aborted::The run stopped early (memory ceiling), so this is not a full result.%0A" \
        "Partial mutation score: n/a (0 mutants)\n"
      )
    end

    it "prints no ::error on a finished run" do
      reporter.summary([build_result(:killed)], invalid_count: 0)
      expect(out.string).not_to include("::error")
    end
  end

  it "percent-encodes newlines and percents in the message" do
    result = build_result(:survived, description: "multi\nline 100%")
    reporter.summary([result], invalid_count: 0)
    warning = out.string.lines.find { |l| l.start_with?("::warning") }
    expect(warning).to include("multi%0Aline 100%25")
    expect(warning.scan("\n").length).to eq(1) # only the trailing newline
  end

  it "handles a root with a trailing slash" do
    reporter = described_class.new(root: "/repo/", out: out)
    reporter.summary([build_result(:survived)], invalid_count: 0)
    warning = out.string.lines.find { |l| l.start_with?("::warning") }
    expect(warning).to start_with("::warning file=lib/calc.rb,line=2,")
  end

  it "percent-encodes carriage returns" do
    reporter.summary([build_result(:survived, description: "carriage\rreturn")], invalid_count: 0)
    warning = out.string.lines.find { |l| l.start_with?("::warning") }
    expect(warning).to include("carriage%0Dreturn")
  end

  it "prints the zero-count block and no annotations for an empty plan" do
    expect { reporter.summary([], invalid_count: 0, empty_plan: true) }.not_to raise_error
    expect(out.string).to include("killed: 0", "skipped: 0", "invalid (discarded): 0")
    expect(out.string).not_to include("Mutation score", "::warning")
  end

  it "still prints progress chars and the count summary" do
    reporter.on_result(build_result(:killed))
    reporter.summary([build_result(:killed)], invalid_count: 0)
    expect(out.string).to start_with(".")
    expect(out.string).to include("killed: 1")
  end
end
