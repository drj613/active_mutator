require "spec_helper"
require "tmpdir"

RSpec.describe ActiveMutator::Reporter::StrykerJson do
  def build_result(status, file:, details: nil)
    source = File.read(file)
    gt = source.byteindex(">")
    edit = ActiveMutator::Edit.new(range: gt...(gt + 1), replacement: ">=",
                                   description: "replace `>` with `>=`", operator: "ConditionalBoundary")
    subject = ActiveMutator::Subject.new(name: "Calc#pos", file: file, byte_range: 0...source.bytesize,
                                         line_range: 1..3, constant_scope: ["Calc"], kind: :instance)
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: ">",
                                           line: 2, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: details)
  end

  around do |ex|
    Dir.mktmpdir do |root|
      @root = root
      @file = File.join(root, "lib", "calc.rb")
      FileUtils.mkdir_p(File.dirname(@file))
      File.write(@file, "def pos(x)\n  x > 0\nend\n")
      FileUtils.mkdir_p(File.join(root, ".active_mutator"))
      ex.run
    end
  end

  let(:out) { StringIO.new }
  let(:reporter) { described_class.new(root: @root, out: out) }
  let(:report_path) { File.join(@root, ".active_mutator", "mutation-report.json") }

  def report_after(results, invalid_count: 0)
    reporter.summary(results, invalid_count: invalid_count)
    JSON.parse(File.read(report_path))
  end

  it "writes a schema-v2 document with integer thresholds" do
    report = report_after([build_result(:killed, file: @file)])
    expect(report["schemaVersion"]).to eq("2")
    expect(report["$schema"]).to eq("https://git.io/mutation-testing-schema")
    expect(report["thresholds"]).to eq("high" => 80, "low" => 60)
    expect(report["projectRoot"]).to eq(@root)
  end

  it "initializes without a coverage map" do
    # White-box: guards the explicit nil default (vs relying on undefined-ivar nil).
    expect(reporter.instance_variables).to include(:@coverage_map)
  end

  it "keys files by root-relative path with source and language" do
    report = report_after([build_result(:killed, file: @file)])
    file_entry = report.dig("files", "lib/calc.rb")
    expect(file_entry["language"]).to eq("ruby")
    expect(file_entry["source"]).to eq(File.read(@file))
  end

  it "maps every status and emits 1-based locations" do
    statuses = { killed: "Killed", survived: "Survived", timeout: "Timeout",
                 error: "RuntimeError", uncovered: "NoCoverage", accepted: "Ignored" }
    results = statuses.keys.map { |s| build_result(s, file: @file) }
    mutants = report_after(results).dig("files", "lib/calc.rb", "mutants")
    expect(mutants.map { |m| m["status"] }).to match_array(statuses.values)
    mutants.each do |m|
      expect(m.dig("location", "start", "line")).to eq(2)
      expect(m.dig("location", "start", "column")).to eq(5)
      expect(m["mutatorName"]).to eq("ConditionalBoundary")
      expect(m["replacement"]).to eq(">=")
    end
    expect(mutants.map { |m| m["id"] }).to eq(%w[0 1 2 3 4 5])
  end

  it "emits the exact location object and the mutant description" do
    mutant = report_after([build_result(:killed, file: @file)]).dig("files", "lib/calc.rb", "mutants").first
    expect(mutant["location"]).to eq(
      "start" => { "line" => 2, "column" => 5 },
      "end" => { "line" => 2, "column" => 6 }
    )
    expect(mutant["description"]).to eq("replace `>` with `>=`")
  end

  it "omits statusReason for killed mutants" do
    mutant = report_after([build_result(:killed, file: @file)]).dig("files", "lib/calc.rb", "mutants").first
    expect(mutant).not_to have_key("statusReason")
  end

  it "puts the ledger note in statusReason for accepted, details for error" do
    mutants = report_after([
      build_result(:accepted, file: @file),
      build_result(:error, file: @file, details: "boom")
    ]).dig("files", "lib/calc.rb", "mutants")
    by_status = mutants.to_h { |m| [m["status"], m] }
    expect(by_status["Ignored"]["statusReason"]).to include(".active_mutator_accepted.json")
    expect(by_status["RuntimeError"]["statusReason"]).to eq("boom")
  end

  it "namespaces extras under config.active_mutator" do
    report = report_after([build_result(:killed, file: @file)], invalid_count: 3)
    expect(report.dig("config", "active_mutator", "invalid_discarded")).to eq(3)
    expect(report.dig("config", "active_mutator", "version")).to eq(ActiveMutator::VERSION)
  end

  it "fills coveredBy and testFiles from an injected coverage map" do
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for).and_return(["./spec/calc_spec.rb[1:1]"])
    reporter.coverage_map = map
    report = report_after([build_result(:survived, file: @file)])
    mutant = report.dig("files", "lib/calc.rb", "mutants").first
    expect(mutant["coveredBy"]).to eq(["./spec/calc_spec.rb[1:1]"])
    tests = report.dig("testFiles", "spec/calc_spec.rb", "tests")
    expect(tests).to eq([{ "id" => "./spec/calc_spec.rb[1:1]", "name" => "./spec/calc_spec.rb[1:1]" }])
  end

  it "fills class-body coveredBy from examples_covering_file, not per-line coverage" do
    source = File.read(@file)
    subject = ActiveMutator::Subject.new(name: "Calc (class body)", file: @file,
                                         byte_range: 0...source.bytesize, line_range: 1..3,
                                         constant_scope: "Calc", kind: :class_body)
    edit = ActiveMutator::Edit.new(range: 0...3, replacement: "", description: "delete `def`",
                                   operator: "StatementDeletion")
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: "def",
                                           line: 1, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    result = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)

    map = instance_double(ActiveMutator::CoverageMap)
    # Per-line coverage would be empty for class-body lines; the reporter must
    # substitute file-covering examples instead, sorted deterministically.
    allow(map).to receive(:examples_covering_file).with(@file)
      .and_return(["./spec/calc_spec.rb[1:2]", "./spec/calc_spec.rb[1:1]"])
    reporter.coverage_map = map
    report = report_after([result])
    expect(report.dig("files", "lib/calc.rb", "mutants").first["coveredBy"])
      .to eq(["./spec/calc_spec.rb[1:1]", "./spec/calc_spec.rb[1:2]"])
  end

  it "omits coveredBy for a class-body mutant when no example covers the file" do
    source = File.read(@file)
    subject = ActiveMutator::Subject.new(name: "Calc (class body)", file: @file,
                                         byte_range: 0...source.bytesize, line_range: 1..3,
                                         constant_scope: "Calc", kind: :class_body)
    edit = ActiveMutator::Edit.new(range: 0...3, replacement: "", description: "delete `def`",
                                   operator: "StatementDeletion")
    mutation = ActiveMutator::Mutation.new(subject: subject, edit: edit, original_snippet: "def",
                                           line: 1, mutated_file_source: "", mutated_def_source: "",
                                           mutated_def_line: 1)
    result = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_covering_file).with(@file).and_return([])
    reporter.coverage_map = map
    report = report_after([result])
    expect(report.dig("files", "lib/calc.rb", "mutants").first).not_to have_key("coveredBy")
  end

  it "sorts the aggregated testFiles example ids deterministically" do
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for)
      .and_return(["./spec/calc_spec.rb[1:1]", "./spec/calc_spec.rb[1:3]", "./spec/calc_spec.rb[1:2]"])
    reporter.coverage_map = map
    report = report_after([build_result(:survived, file: @file)])
    tests = report.dig("testFiles", "spec/calc_spec.rb", "tests").map { |t| t["id"] }
    expect(tests).to eq(["./spec/calc_spec.rb[1:1]", "./spec/calc_spec.rb[1:2]", "./spec/calc_spec.rb[1:3]"])
  end

  it "omits coveredBy and testFiles without a map" do
    report = report_after([build_result(:survived, file: @file)])
    expect(report.dig("files", "lib/calc.rb", "mutants").first).not_to have_key("coveredBy")
    expect(report).not_to have_key("testFiles")
  end

  it "maps skipped to Ignored with the reason" do
    mutant = report_after([build_result(:skipped, file: @file, details: "constant not loaded")])
             .dig("files", "lib/calc.rb", "mutants").first
    expect(mutant["status"]).to eq("Ignored")
    expect(mutant["statusReason"]).to eq("constant not loaded")
  end

  it "prints the report path and progress chars" do
    reporter.on_result(build_result(:killed, file: @file))
    reporter.summary([build_result(:killed, file: @file)], invalid_count: 0)
    expect(out.string).to eq(".\n\nStryker report written to .active_mutator/mutation-report.json\n")
  end
end
