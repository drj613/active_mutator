RSpec.describe ActiveMutator::TestAudit do
  let(:a) { "./spec/a_spec.rb[1:1]" }
  let(:b) { "./spec/a_spec.rb[1:2]" }
  let(:c) { "./spec/c_spec.rb[1:1]" }
  let(:d) { "./spec/d_spec.rb[1:1]" }

  def mutant(name, class_body: false)
    double(name, subject: double(class_body?: class_body))
  end

  def result(mutation, status, killed_by: [], passed: {})
    ActiveMutator::Result.new(mutation: mutation, status: status, details: nil, killed_by: killed_by, passed: passed)
  end

  def passes(*ids) = ids.to_h { |id| [id, "#{id.sub(/\[.*/, "")}:#{ids.index(id) + 1}"] }

  # `answers` maps each mutant to a block that gets the suspects it ran
  # against and returns its audit Result. Every round is recorded.
  def audit(results, example_ids, answers = {}, width: 4)
    @rounds = []
    run = lambda do |items|
      @rounds << items
      items.map { |mutation, ids| answers.fetch(mutation).call(ids) }
    end
    described_class.new(results: results, example_ids: example_ids, width: width,
                        build: ->(mutation, ids) { [mutation, ids] }, run: run).call
  end

  let(:m1) { mutant("m1") }
  let(:m2) { mutant("m2") }
  let(:m3) { mutant("m3") }

  it "flags an example that passed against a killed mutant and killed nothing" do
    report = audit([result(m1, :killed, killed_by: [a])], { m1 => [a, b] },
                   { m1 => ->(ids) { result(m1, :survived, passed: { b => "./spec/a_spec.rb:7" }) } })

    expect(@rounds).to eq([[[m1, [b]]]])
    expect(report.flagged).to eq([described_class::Flag.new(id: b, location: "./spec/a_spec.rb:7", killable: 1)])
    expect(report.cleared).to eq(1)
    expect(report.not_judged).to eq([])
    expect(report.mutants_run).to eq(1)
  end

  it "counts every killed mutant a flagged example covers" do
    results = [result(m1, :killed, killed_by: [a]), result(m2, :killed, killed_by: [a]), result(m3, :survived)]
    answers = { m1 => ->(_) { result(m1, :survived, passed: passes(b)) },
                m2 => ->(_) { result(m2, :survived, passed: passes(b)) } }
    report = audit(results, { m1 => [a, b], m2 => [b, a], m3 => [b] }, answers)

    expect(report.flagged.map { |f| [f.id, f.killable] }).to eq([[b, 2]])
  end

  it "clears an example the moment it kills, and never runs a mutant with no suspects left" do
    results = [result(m1, :killed, killed_by: [a]), result(m2, :killed, killed_by: [a])]
    answers = { m1 => ->(_) { result(m1, :killed, killed_by: [b], passed: passes(c)) } }
    report = audit(results, { m1 => [a, b, c], m2 => [a, b] }, answers, width: 1)

    expect(@rounds).to eq([[[m1, [b, c]]]])
    expect(report.flagged.map(&:id)).to eq([c])
    expect(report.cleared).to eq(2)
    expect(report.kills).to eq(m1 => [b])
    expect(report.mutants_run).to eq(1)
  end

  it "runs the mutants with the most suspects first, ties in plan order" do
    results = [m1, m2, m3].map { |m| result(m, :killed, killed_by: [a]) }
    answers = [m1, m2, m3].to_h { |m| [m, ->(_) { result(m, :survived) }] }
    audit(results, { m1 => [a, b], m2 => [a, b, c], m3 => [a, c] }, answers, width: 1)

    expect(@rounds.map { |round| round.map(&:first) }).to eq([[m2], [m1], [m3]])
  end

  it "rebuilds each round from the suspects still standing" do
    results = [m1, m2, m3].map { |m| result(m, :killed, killed_by: [a]) }
    answers = { m1 => ->(_) { result(m1, :killed, killed_by: [c]) },
                m2 => ->(_) { result(m2, :killed, killed_by: [b]) },
                m3 => ->(_) { result(m3, :survived, passed: passes(d)) } }
    report = audit(results, { m1 => [a, b, c], m2 => [a, b, d], m3 => [a, b, c, d] }, answers, width: 2)

    expect(@rounds).to eq([[[m3, [b, c, d]], [m1, [b, c]]], [[m2, [b, d]]]])
    expect(report.flagged.map(&:id)).to eq([d])
  end

  it "runs each mutant once, whatever is left after its round" do
    results = [result(m1, :killed, killed_by: [a])]
    report = audit(results, { m1 => [a, b] }, { m1 => ->(_) { result(m1, :timeout) } })

    expect(@rounds.size).to eq(1)
    expect(report.mutants_run).to eq(1)
  end

  it "keeps a suspect's phase-1 order when building its work item" do
    results = [result(m1, :killed, killed_by: [b])]
    audit(results, { m1 => [d, b, a, c] }, { m1 => ->(_) { result(m1, :survived) } })

    expect(@rounds.first.first.last).to eq([d, a, c])
  end

  it "does not run anything when every covering example already killed" do
    report = audit([result(m1, :killed, killed_by: [a])], { m1 => [a] })

    expect(@rounds).to eq([])
    expect(report.flagged).to eq([])
    expect(report.cleared).to eq(1)
    expect(report.mutants_run).to eq(0)
  end

  it "does not judge examples that cover only survivors, accepted, skipped, timed-out, or errored mutants" do
    results = %i[survived accepted skipped timeout error].each_with_index.map do |status, i|
      result(mutant("m#{i}"), status)
    end
    ids = results.to_h { |r| [r.mutation, [a]] }
    report = audit(results, ids)

    expect(@rounds).to eq([])
    expect(report.not_judged).to eq([a])
    expect(report.flagged).to eq([])
  end

  it "never credits or re-runs a kill with no killer" do
    report = audit([result(m1, :killed)], { m1 => [a, b] })

    expect(@rounds).to eq([])
    expect(report.not_judged).to eq([a, b])
  end

  it "skips class-body mutants, but a kill of one still clears its killer" do
    body = mutant("body", class_body: true)
    results = [result(body, :killed, killed_by: [a]), result(m1, :killed, killed_by: [b])]
    report = audit(results, { body => [a, c], m1 => [a, b] })

    expect(@rounds).to eq([])
    expect(report.cleared).to eq(2)
    expect(report.not_judged).to eq([])
    expect(report.flagged).to eq([])
  end

  it "leaves out examples that only class-body mutants ran against" do
    body = mutant("body", class_body: true)
    report = audit([result(body, :survived)], { body => [c] })

    expect(report.not_judged).to eq([])
    expect(report.cleared).to eq(0)
  end

  %i[timeout error skipped].each do |status|
    it "blames nobody when the audit fork ends in #{status}" do
      results = [result(m1, :killed, killed_by: [a])]
      report = audit(results, { m1 => [a, b] }, { m1 => ->(_) { result(m1, status, passed: passes(b)) } })

      expect(report.flagged).to eq([])
      expect(report.not_judged).to eq([b])
    end
  end

  it "blames nobody when the audit fork failed without naming a killer" do
    results = [result(m1, :killed, killed_by: [a])]
    report = audit(results, { m1 => [a, b, c] }, { m1 => ->(_) { result(m1, :killed, passed: passes(b)) } })

    expect(report.flagged).to eq([])
    expect(report.not_judged).to eq([b, c])
    expect(report.kills).to eq({})
  end

  it "does not judge a suspect the audit fork never reported as passed (pending, skipped)" do
    results = [result(m1, :killed, killed_by: [a])]
    report = audit(results, { m1 => [a, b, c] }, { m1 => ->(_) { result(m1, :survived, passed: passes(b)) } })

    expect(report.flagged.map(&:id)).to eq([b])
    expect(report.not_judged).to eq([c])
  end

  it "treats two spellings of one example as the same example" do
    absolute = ->(id) { id.sub("./", "#{Dir.pwd}/") }
    results = [result(m1, :killed, killed_by: [absolute.call(a)])]
    report = audit(results, { m1 => [a, b] },
                   { m1 => ->(_) { result(m1, :survived, passed: { absolute.call(b) => "./spec/a_spec.rb:2" }) } })

    expect(@rounds.first.first.last).to eq([b])
    expect(report.flagged).to eq([described_class::Flag.new(id: b, location: "./spec/a_spec.rb:2", killable: 1)])
    expect(report.cleared).to eq(1)
  end

  it "keeps the first location seen for an example" do
    results = [result(m1, :killed, killed_by: [a]), result(m2, :killed, killed_by: [a])]
    answers = { m1 => ->(_) { result(m1, :survived, passed: { b => "first:1" }) },
                m2 => ->(_) { result(m2, :survived, passed: { b => "second:2" }) } }
    report = audit(results, { m1 => [a, b], m2 => [a, b] }, answers, width: 1)

    expect(report.flagged.map(&:location)).to eq(["first:1"])
  end

  it "adds up every kill the audit saw per mutant" do
    results = [result(m1, :killed, killed_by: [a])]
    report = audit(results, { m1 => [a, b, c] }, { m1 => ->(_) { result(m1, :killed, killed_by: [b, c]) } })

    expect(report.kills).to eq(m1 => [b, c])
    expect(report.cleared).to eq(3)
  end

  it "lists flagged and unjudged examples sorted by id" do
    results = [result(m1, :killed, killed_by: [a]), result(m2, :survived)]
    report = audit(results, { m1 => [a, d, b], m2 => [c, "./spec/b_spec.rb[1:1]"] },
                   { m1 => ->(_) { result(m1, :survived, passed: passes(d, b)) } })

    expect(report.flagged.map(&:id)).to eq([b, d])
    expect(report.not_judged).to eq(["./spec/b_spec.rb[1:1]", c])
  end
end
