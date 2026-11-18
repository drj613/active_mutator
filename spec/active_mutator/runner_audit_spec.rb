RSpec.describe ActiveMutator::Runner do
  let(:config) { ActiveMutator::CLI.parse([]).with(root: "/project", jobs: 3, audit_tests: true) }
  let(:subject_) do
    ActiveMutator::Subject.new(name: "A#x", file: "/project/lib/a.rb", byte_range: 0...10, line_range: 1..3,
                               constant_scope: "A", kind: :instance)
  end
  let(:a) { "./spec/a_spec.rb[1:1]" }
  let(:b) { "./spec/a_spec.rb[1:2]" }
  let(:browser) { "./spec/system/a_spec.rb[1:1]" }
  let(:map) { instance_double(ActiveMutator::CoverageMap, time_for: 0.5) }

  def mutation(line)
    ActiveMutator::Mutation.new(
      subject: subject_, edit: ActiveMutator::Edit.new(range: 5...6, replacement: ">=", description: "d"),
      original_snippet: ">", line: line, mutated_file_source: "", mutated_def_source: "def x = 1", mutated_def_line: 1
    )
  end

  def result(mutation, status, **fields)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: nil, **fields)
  end

  describe "#audit_tests" do
    let(:m1) { mutation(2) }
    let(:m2) { mutation(3) }

    it "runs killed mutants again against their suspects and adds the audit's kills to killed_by" do
      scheduler = instance_double(ActiveMutator::Scheduler)
      allow(scheduler).to receive(:run) { [result(m1, :killed, killed_by: [b])] }
      results = [result(m1, :killed, killed_by: [a]), result(m2, :survived)]

      merged, report = described_class.new(config).audit_tests(results, scheduler, map,
                                                               phase1_ids: { m1 => [a, b, browser], m2 => [a] })

      expect(scheduler).to have_received(:run) do |items|
        expect(items.map(&:example_ids)).to eq([[b, browser]])
        # Built like any work item: the lane and budget come from the suspects.
        expect(items.first.lane).to eq(:serial)
        expect(items.first.timeout).to eq(0.5 * config.timeout_factor + config.timeout_floor +
                                          config.browser_boot_seconds)
      end
      expect(merged.map(&:killed_by)).to eq([[a, b], []])
      expect(merged.last).to be(results.last)
      expect(report.kills).to eq(m1 => [b])
      expect(report.not_judged).to eq([browser])
    end

    it "builds rounds as wide as --jobs" do
      mutants = (2..5).map { |line| mutation(line) }
      scheduler = instance_double(ActiveMutator::Scheduler)
      rounds = []
      allow(scheduler).to receive(:run) do |items|
        rounds << items.size
        items.map { |i| result(i.mutation, :survived) }
      end
      results = mutants.map { |m| result(m, :killed, killed_by: [a]) }

      described_class.new(config).audit_tests(results, scheduler, map, phase1_ids: mutants.to_h { |m| [m, [a, b]] })

      expect(rounds).to eq([3, 1])
    end

    it "runs in its own phase, on a scheduler of audit workers" do
      seen = []
      bus = ActiveMutator::Events.new.subscribe { |e| seen << [e.type, e.fields] }
      allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
      runner = described_class.new(config, events: bus)

      runner.audit_tests([], nil, map, phase1_ids: { m1 => [a], m2 => [a] })

      expect(ActiveMutator::Scheduler).to have_received(:new)
        .with(jobs: 3, worker: described_class::AUDIT_WORKER, events: bus, first_seq: 3,
              abort: runner.instance_variable_get(:@abort))
      expect(seen).to eq([[:phase_start, { phase: :auditing }], [:phase_end, { phase: :auditing }]])
    end

    it "re-raises an aborted audit with the verdicts it was given, which are all final" do
      scheduler = instance_double(ActiveMutator::Scheduler)
      in_flight = [{ seq: 4 }]
      allow(scheduler).to receive(:run).and_raise(ActiveMutator::Aborted.new(:sigterm, results: [], in_flight: in_flight))
      results = [result(m1, :killed, killed_by: [a])]

      expect do
        described_class.new(config).audit_tests(results, scheduler, map, phase1_ids: { m1 => [a, b] })
      end.to raise_error(ActiveMutator::Aborted) { |e| expect([e.reason, e.results, e.in_flight]).to eq([:sigterm, results, in_flight]) }
    end
    it "keeps the killers the audit already saw when it is stopped" do
      scheduler = instance_double(ActiveMutator::Scheduler)
      c = "./spec/c_spec.rb[1:1]"
      calls = 0
      allow(scheduler).to receive(:run) do
        calls += 1
        next [result(m1, :killed, killed_by: [b])] if calls == 1

        raise ActiveMutator::Aborted.new(:sigterm, results: [result(m2, :killed, killed_by: [c])])
      end
      results = [result(m1, :killed, killed_by: [a]), result(m2, :killed, killed_by: [a])]

      expect do
        described_class.new(config.with(jobs: 1)).audit_tests(results, scheduler, map,
                                                              phase1_ids: { m1 => [a, b], m2 => [a, c] })
      end.to raise_error(ActiveMutator::Aborted) { |e| expect(e.results.map(&:killed_by)).to eq([[a, b], [a, c]]) }
    end
  end

  describe "AUDIT_WORKER" do
    it "runs the worker with fail-fast off" do
      writer = StringIO.new
      allow(ActiveMutator::Worker).to receive(:run)
      described_class::AUDIT_WORKER.call(:mutation, [:ids], writer)
      expect(ActiveMutator::Worker).to have_received(:run).with(:mutation, [:ids], writer, audit: true)
    end
  end

  describe "a run with --audit-tests" do
    let(:seen) { [] }
    let(:bus) { ActiveMutator::Events.new.subscribe { |e| seen << [e.type, e.fields[:phase]] } }
    let(:summaries) { [] }
    let(:reporter) do
      r = Object.new
      calls = summaries
      def r.coverage_map=(_); end
      def r.on_result(_); end
      r.define_singleton_method(:summary) { |results, **kwargs| calls << kwargs.merge(results: results) }
      r
    end

    def run_with(cfg)
      runner = described_class.new(cfg, reporter: reporter, events: bus)
      yield runner if block_given?
      allow(runner).to receive(:preload!)
      allow(runner).to receive(:preload_spec_helper!)
      allow(runner).to receive(:discover).and_return(
        described_class::Discovery.new(subjects: [], scanned_files: [], since_candidates: [],
                                       since_matched_all: [], since_filter: nil)
      )
      allow(ActiveMutator::Baseline).to receive(:new).and_return(instance_double(ActiveMutator::Baseline, coverage_map: map))
      allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
      runner.call
    end

    def phases = seen.select { |(type, _)| type == :phase_start }.map(&:last)

    it "audits after escalation, before the report" do
      expect { run_with(config) }.not_to output.to_stderr
      expect(phases).to eq(%i[boot planning mutating auditing reporting])
    end

    # A trip inside the run's deferred block only records the reason.
    def trip(runner, value)
      runner.instance_variable_get(:@abort).trip!(:sigterm)
      value
    end

    it "does not start the audit after a stop during escalation" do
      code = run_with(config) do |runner|
        allow(runner).to receive(:escalate_class_body_survivors) { |done, *| trip(runner, done) }
        allow(runner).to receive(:audit_tests)
      end
      expect(code).to eq(143)
      expect(phases).not_to include(:auditing)
    end

    it "reports a stop during the audit with every finished verdict" do
      finished = [result(mutation(2), :killed)]
      code = run_with(config) do |runner|
        allow(runner).to receive(:audit_tests) { trip(runner, [finished, nil]) }
      end
      expect(code).to eq(143)
      expect(summaries.last).to include(:aborted, results: finished)
    end

    it "hands the audit report to the reporter" do
      run_with(config)
      expect(summaries.last[:test_audit]).to be_a(ActiveMutator::TestAudit::Report)
    end

    def flagged_report
      ActiveMutator::TestAudit::Report.new(
        flagged: [ActiveMutator::TestAudit::Flag.new(id: a, location: "./spec/a_spec.rb:1", killable: 1)],
        cleared: 0, not_judged: [], kills: {}, mutants_run: 1
      )
    end

    it "exits 1 with --fail-on-no-kills when the audit flags a test, and tells the reporter" do
      code = run_with(config.with(fail_on_no_kills: true)) do |runner|
        allow(runner).to receive(:audit_tests) { |done, *| [done, flagged_report] }
      end
      expect(code).to eq(1)
      expect(summaries.last[:test_audit].fail_on_flags).to be(true)
    end

    it "exits 0 with --fail-on-no-kills when nothing is flagged" do
      expect(run_with(config.with(fail_on_no_kills: true))).to eq(0)
    end

    it "does not fail the run on flags without --fail-on-no-kills" do
      code = run_with(config) do |runner|
        allow(runner).to receive(:audit_tests) { |done, *| [done, flagged_report] }
      end
      expect(code).to eq(0)
      expect(summaries.last[:test_audit].fail_on_flags).to be(false)
    end

    it "does not audit without the flag, or pass the reporter a test_audit keyword" do
      run_with(config.with(audit_tests: false))
      expect(phases).not_to include(:auditing)
      expect(summaries.last).not_to have_key(:test_audit)
    end

    it "does not audit a run narrowed by path arguments, and says so" do
      expect { run_with(config.with(paths: ["lib"])) }
        .to output("active_mutator: --audit-tests needs a full run; skipping the audit (narrowed by path arguments)\n")
        .to_stderr
      expect(phases).not_to include(:auditing)
    end

    it "warns that it skips the audit even when a scoped run plans nothing" do
      expect { run_with(config.with(since: "main", allow_empty: true)) }
        .to output(/--audit-tests needs a full run; skipping the audit \(narrowed by --since/).to_stderr
    end

    it "audits with --no-class-level, which leaves every def mutant in" do
      run_with(config.with(class_level: false))
      expect(phases).to include(:auditing)
    end
  end

  describe "the full-run check" do
    def check(**fields)
      described_class.new(config.with(**fields)).send(:full_run_for_audit?)
    end

    it "names every flag that narrows the run" do
      expect { expect(check(since: "main", subject_filter: "A", max_mutants: 3, paths: ["lib"])).to be(false) }
        .to output("active_mutator: --audit-tests needs a full run; skipping the audit " \
                   "(narrowed by --since/--changed, --subject, --max-mutants, path arguments)\n").to_stderr
    end

    { since: "HEAD", subject_filter: "A#x", max_mutants: 1 }.each do |field, value|
      it "fails on #{field} alone" do
        expect { expect(check(field => value)).to be(false) }.to output(/skipping the audit/).to_stderr
      end
    end

    it "passes a full run" do
      expect { expect(check).to be(true) }.not_to output.to_stderr
    end
  end
end
