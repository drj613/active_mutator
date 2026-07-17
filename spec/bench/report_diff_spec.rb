require_relative "../../bench/lib/bench/report_diff"

RSpec.describe Bench::ReportDiff do
  def mutant(file: "lib/a.rb", line: 3, column: 5, op: "BinaryOperator",
             replacement: "<=", status: "Killed")
    [file, { "mutatorName" => op, "replacement" => replacement, "status" => status,
             "location" => { "start" => { "line" => line, "column" => column },
                             "end" => { "line" => line, "column" => column + 2 } } }]
  end

  def report(mutants)
    files = Hash.new { |h, k| h[k] = { "mutants" => [] } }
    mutants.each { |file, m| files[file]["mutants"] << m }
    { "files" => files }
  end

  it "computes the mutation score of each report (detected / detected + survived)" do
    a = report([mutant(status: "Killed"), mutant(line: 9, status: "Survived"),
                mutant(line: 12, status: "Timeout"), mutant(line: 20, status: "NoCoverage")])
    diff = described_class.new(a, a).call
    expect(diff[:score_a]).to eq(66.67) # 2 detected (Killed+Timeout) / 3 scoreable; NoCoverage excluded
    expect(diff[:score_b]).to eq(66.67)
    expect(diff[:score_delta]).to eq(0.0)
  end

  it "lists status transitions keyed by file/line/column/operator/replacement" do
    a = report([mutant(status: "Killed")])
    b = report([mutant(status: "Timeout")])
    diff = described_class.new(a, b).call
    expect(diff[:transitions]).to eq(
      [{ key: "lib/a.rb:3:5 BinaryOperator <=", from: "Killed", to: "Timeout" }]
    )
  end

  it "reports mutants present in only one run" do
    a = report([mutant, mutant(line: 9)])
    b = report([mutant])
    diff = described_class.new(a, b).call
    expect(diff[:only_in_a]).to eq(["lib/a.rb:9:5 BinaryOperator <="])
    expect(diff[:only_in_b]).to eq([])
  end

  it "has no transitions when statuses match" do
    a = report([mutant, mutant(line: 9, status: "Survived")])
    expect(described_class.new(a, a).call[:transitions]).to eq([])
  end
end
