require "tmpdir"
require "fileutils"
require "timeout"

RSpec.describe ActiveMutator::Runner do
  let(:config) do
    ActiveMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: "/project", preload_helper: nil, serial_patterns: ["spec/system/", "spec/features/"],
      spec_paths: ["spec"],
      browser_boot_seconds: 15.0, accept_survivors: false, exclude: [],
      max_mutants: nil, debug_plan: false, fail_at: nil, adaptive_timeout: true,
      operators: [], class_level: true, class_level_closure_cap: 10, allow_empty: false
    )
  end

  let(:subject_) do
    ActiveMutator::Subject.new(name: "A#x", file: "/project/lib/a.rb",
                             byte_range: 0...10, line_range: 1..3,
                             constant_scope: "A", kind: :instance)
  end

  def discovery(subjects, scanned_files: ["lib/a.rb"], since_candidates: [], since_matched_all: subjects,
                comment_only: [])
    filter = instance_double(ActiveMutator::SinceFilter)
    allow(filter).to receive(:comment_only?) { |file| comment_only.include?(file) }
    ActiveMutator::Runner::Discovery.new(subjects: subjects, scanned_files: scanned_files,
                                         since_candidates: since_candidates, since_matched_all: since_matched_all,
                                         since_filter: filter)
  end

  def mutation(line: 2)
    ActiveMutator::Mutation.new(
      subject: subject_,
      edit: ActiveMutator::Edit.new(range: 5...6, replacement: ">=", description: "d"),
      original_snippet: ">", line: line,
      mutated_file_source: "", mutated_def_source: "def x = 1", mutated_def_line: 1
    )
  end

  it "builds work items with lanes and reports uncovered ones" do
    covered = mutation(line: 2)
    uncovered = mutation(line: 3)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", [2, 1, 3]).and_return(["./spec/a_spec.rb[1:1]"])
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", [3, 1, 2]).and_return([])
    allow(map).to receive(:time_for).and_return(0.5)

    items, uncovered_results = described_class.new(config).plan_work([covered, uncovered], map)

    expect(items.size).to eq(1)
    expect(items.first.lane).to eq(:parallel)
    expect(items.first.timeout).to eq(0.5 * 4.0 + 2.0)
    expect(uncovered_results.map(&:status)).to eq([:uncovered])
  end

  it "assigns the serial lane and budget bump to browser-covered mutants" do
    m = mutation(line: 2)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for)
      .and_return(["./spec/system/extractions_spec.rb[1:1]", "./spec/a_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(1.0)

    items, = described_class.new(config).plan_work([m], map)
    expect(items.first.lane).to eq(:serial)
    expect(items.first.timeout).to eq(1.0 * 4.0 + 2.0 + 15.0)
  end

  it "records the variable and fixed budget parts on the work item" do
    m = mutation(line: 2)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.5)

    items, = described_class.new(config).plan_work([m], map)
    item = items.first
    expect(item.variable).to eq(map.time_for(item.example_ids) * config.timeout_factor)
    expect(item.timeout).to eq(item.variable + config.timeout_floor)
  end

  it "adds the serial lane's browser boot to the timeout budget" do
    m = mutation(line: 2)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for)
      .and_return(["./spec/system/extractions_spec.rb[1:1]", "./spec/a_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(1.0)

    items, = described_class.new(config).plan_work([m], map)
    serial_item = items.first
    expect(serial_item.lane).to eq(:serial)
    expect(serial_item.timeout)
      .to eq(serial_item.variable + config.timeout_floor + config.browser_boot_seconds)
  end

  it "plans a mutant whose own line is uncovered when the subject's line range is covered" do
    # Line coverage attributes multi-line expressions to their anchor line, so
    # a sub-expression mutant's own line may have no coverage entry at all.
    m = mutation(line: 2)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for) do |_file, lines|
      lines.include?(1) ? ["./spec/a_spec.rb[1:1]"] : []
    end
    allow(map).to receive(:time_for).and_return(0.5)

    items, pre_results = described_class.new(config).plan_work([m], map)

    expect(pre_results).to be_empty
    expect(items.size).to eq(1)
    expect(items.first.example_ids).to eq(["./spec/a_spec.rb[1:1]"])
  end

  it "looks up examples for the union of the mutation's lines and the subject's line range" do
    m = mutation(line: 2)
    map = instance_double(ActiveMutator::CoverageMap)
    looked_up = nil
    allow(map).to receive(:examples_for) do |_file, lines|
      looked_up = lines.to_a
      ["./spec/a_spec.rb[1:1]"]
    end
    allow(map).to receive(:time_for).and_return(0.5)

    described_class.new(config).plan_work([m], map)

    expect(looked_up).to match_array([1, 2, 3])
  end

  it "builds a StrykerJson reporter for :stryker_json format" do
    stryker_config = config.with(format: :stryker_json)
    reporter = described_class.new(stryker_config).instance_variable_get(:@reporter)
    expect(reporter).to be_a(ActiveMutator::Reporter::StrykerJson)
  end

  it "builds a Github reporter for :github format" do
    github_config = config.with(format: :github)
    reporter = described_class.new(github_config).instance_variable_get(:@reporter)
    expect(reporter).to be_a(ActiveMutator::Reporter::Github)
  end

  describe "#call adaptive-timeout wiring" do
    let(:reporter) do
      r = Object.new
      def r.coverage_map=(_); end
      def r.on_result(_); end
      def r.summary(*, **); end
      r
    end

    def stub_runner(cfg)
      runner = described_class.new(cfg, reporter: reporter)
      allow(runner).to receive(:preload!)
      allow(runner).to receive(:preload_spec_helper!)
      allow(runner).to receive(:discover).and_return(discovery([]))
      allow(ActiveMutator::Baseline).to receive(:new).and_return(
        instance_double(ActiveMutator::Baseline, coverage_map: instance_double(ActiveMutator::CoverageMap))
      )
      runner
    end

    it "passes per-lane TimeoutCalibrators to the scheduler when adaptive_timeout is on" do
      runner = stub_runner(config.with(adaptive_timeout: true))
      expect(ActiveMutator::Scheduler).to receive(:new)
        .with(hash_including(calibrators: {
          parallel: kind_of(ActiveMutator::TimeoutCalibrator),
          serial: kind_of(ActiveMutator::TimeoutCalibrator)
        }))
        .and_return(instance_double(ActiveMutator::Scheduler, run: []))
      runner.call
    end

    it "builds distinct calibrator instances per lane (no cross-lane sample pooling)" do
      runner = stub_runner(config.with(adaptive_timeout: true))
      captured = nil
      expect(ActiveMutator::Scheduler).to receive(:new) do |**kwargs|
        captured = kwargs[:calibrators]
        instance_double(ActiveMutator::Scheduler, run: [])
      end
      runner.call
      expect(captured[:parallel]).not_to be(captured[:serial])
    end

    it "passes no calibrators when adaptive_timeout is off" do
      runner = stub_runner(config.with(adaptive_timeout: false))
      expect(ActiveMutator::Scheduler).to receive(:new)
        .with(hash_including(calibrators: nil))
        .and_return(instance_double(ActiveMutator::Scheduler, run: []))
      runner.call
    end

    it "brackets each step of the run in a phase" do
      seen = []
      bus = ActiveMutator::Events.new.subscribe { |e| seen << [e.type, e.fields] }
      runner = described_class.new(config, reporter: reporter, events: bus)
      allow(runner).to receive(:preload!)
      allow(runner).to receive(:preload_spec_helper!)
      allow(runner).to receive(:discover).and_return(discovery([]))
      allow(ActiveMutator::Baseline).to receive(:new).and_return(
        instance_double(ActiveMutator::Baseline, coverage_map: instance_double(ActiveMutator::CoverageMap))
      )
      allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))

      runner.call

      expect(seen.reject { |(type, _)| type == :memory }).to eq([
                           [:phase_start, { phase: :boot }], [:phase_end, { phase: :boot }],
                           [:phase_start, { phase: :planning }], [:phase_end, { phase: :planning }],
                           [:phase_start, { phase: :mutating, mutants: 0 }], [:phase_end, { phase: :mutating }],
                           [:phase_start, { phase: :reporting }], [:phase_end, { phase: :reporting }]
                         ])
      expect(ActiveMutator::Baseline).to have_received(:new).with(hash_including(events: bus))
      expect(ActiveMutator::Scheduler).to have_received(:new).with(hash_including(events: bus))
    end

    it "prints diagnostic lines to stderr with --diagnostics, and none without" do
      [true, false].each do |on|
        runner = stub_runner(config.with(diagnostics: on))
        allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
        expectation = output(on ? /\] phase boot start\n/ : /phase/).to_stderr_from_any_process
        on ? expect { runner.call }.to(expectation) : expect { runner.call }.not_to(expectation)
      end
    end

    it "writes every event to the --events file, relative to the root, and closes it" do
      Dir.mktmpdir do |dir|
        runner = stub_runner(config.with(root: dir, events_file: "run.ndjson"))
        allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
        opened = nil
        allow(File).to receive(:open).and_wrap_original { |orig, *args| opened = orig.call(*args) }

        runner.call

        lines = File.readlines(File.join(dir, "run.ndjson")).map { |l| JSON.parse(l) }
        expect(lines.map { |l| [l["event"], l["phase"]] }.first(3))
          .to eq([%w[phase_start boot], ["memory", nil], %w[phase_end boot]]) # a sample at each boundary
        expect(lines.map { |l| l["v"] }.uniq).to eq([1])
        expect(opened).to be_closed
      end
    end

    it "reports an unwritable --events file as a usage error" do
      runner = stub_runner(config.with(events_file: "/nonexistent/dir/run.ndjson"))
      expect { runner.call }.to raise_error(ActiveMutator::Error, /\Acannot write --events file: No such file or directory/)
    end

    it "samples memory only when something reads the samples, and stops the sampler after" do
      sampler = instance_double(ActiveMutator::Sampler, call: nil, stop: nil)
      allow(sampler).to receive(:start).and_return(sampler)
      allow(ActiveMutator::Sampler).to receive(:new).and_return(sampler)
      allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))

      stub_runner(config).call
      expect(ActiveMutator::Sampler).not_to have_received(:new)

      expect { stub_runner(config.with(diagnostics: true, sample_interval: 0.5)).call }.to output.to_stderr_from_any_process
      expect(ActiveMutator::Sampler).to have_received(:new).with(events: kind_of(ActiveMutator::Events), interval: 0.5)
      expect(sampler).to have_received(:stop)
    end

    it "sets ClosureReload.cap from config before scheduling (forks inherit it)" do
      original_cap = ActiveMutator::ClosureReload.cap
      runner = stub_runner(config.with(class_level_closure_cap: 42))
      allow(ActiveMutator::Scheduler).to receive(:new)
        .and_return(instance_double(ActiveMutator::Scheduler, run: []))
      runner.call
      expect(ActiveMutator::ClosureReload.cap).to eq(42)
    ensure
      ActiveMutator::ClosureReload.cap = original_cap
    end

    describe "aborting" do
      let(:seen) { [] }
      let(:bus) { ActiveMutator::Events.new.subscribe { |e| seen << [e.type, e.fields] } }

      let(:summaries) { [] }
      let(:reporter) do
        calls = summaries
        r = Object.new
        r.define_singleton_method(:on_result) { |_| nil }
        r.define_singleton_method(:summary) { |results, **kw| calls << [results, kw] }
        r
      end

      def aborting_runner(&run)
        runner = described_class.new(config, reporter: reporter, events: bus)
        allow(runner).to receive(:preload!)
        allow(runner).to receive(:preload_spec_helper!)
        allow(runner).to receive(:discover).and_return(discovery([]))
        allow(ActiveMutator::Baseline).to receive(:new).and_return(
          instance_double(ActiveMutator::Baseline, coverage_map: instance_double(ActiveMutator::CoverageMap))
        )
        scheduler = instance_double(ActiveMutator::Scheduler)
        allow(scheduler).to receive(:run, &run)
        allow(ActiveMutator::Scheduler).to receive(:new).and_return(scheduler)
        runner
      end

      def abort_event = seen.find { |(type, _)| type == :abort }&.last

      { "TERM" => [:sigterm, 143], "INT" => [:sigint, 130] }.each do |sig, (reason, code)|
        it "exits #{code} on SIG#{sig}, emitting abort and leaving the phase open" do
          # Like the real scheduler: the trap only trips the flag, and the
          # poll loop raises.
          runner = aborting_runner do
            flag = runner.instance_variable_get(:@abort)
            Process.kill(sig, Process.pid)
            Timeout.timeout(5) { sleep 0.01 until flag.tripped? }
            raise ActiveMutator::Aborted, flag.reason
          end

          expect(runner.call).to eq(code)
          expect(abort_event).to eq(reason: reason, in_flight: [], planned: 0,
                                    counts: ActiveMutator::Reporter::Terminal.counts([]), score: nil)
          expect(summaries).to eq([[[], { invalid_count: 0, aborted: { reason: reason, in_flight: [], planned: 0 } }]])
          expect(seen.reject { |(type, _)| type == :memory }.last(2).map { |(type, fields)| [type, fields[:phase]] })
            .to eq([[:phase_start, :mutating], [:abort, nil]])
        end
      end

      it "gives the host its own signal handlers back, including an ignored one" do
        host = proc {}
        previous_term = trap("TERM", host)
        previous_int = trap("INT", nil)
        aborting_runner { [] }.call
        expect(trap("TERM", previous_term)).to be(host)
        expect(trap("INT", previous_int)).to be_nil
      end

      it "hands its one flag to the baseline and the scheduler" do
        runner = aborting_runner { [] }
        runner.call
        flag = runner.instance_variable_get(:@abort)
        expect(ActiveMutator::Baseline).to have_received(:new).with(hash_including(abort: flag))
        expect(ActiveMutator::Scheduler).to have_received(:new).with(hash_including(abort: flag))
      end

      it "exits 3 on a memory ceiling abort, counting what finished plus the pre-resolved mutants" do
        killed = ActiveMutator::Result.new(mutation: mutation, status: :killed, details: nil)
        survived = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
        uncovered = ActiveMutator::Result.new(mutation: mutation, status: :uncovered, details: nil)
        in_flight = [{ seq: 3 }]
        runner = aborting_runner do
          raise ActiveMutator::Aborted.new(:memory_ceiling, results: [killed, survived], in_flight: in_flight)
        end
        allow(runner).to receive(:plan_work).and_return([[], [uncovered], {}])

        expect(runner.call).to eq(3)
        expect(abort_event).to include(reason: :memory_ceiling, in_flight: in_flight, score: 0.5)
        expect(abort_event[:counts]).to include(killed: 1, survived: 1, uncovered: 1)
        expect(summaries).to eq([[[killed, survived, uncovered],
                                  { invalid_count: 0, aborted: { reason: :memory_ceiling, in_flight: in_flight,
                                                                 planned: 0 } }]])
      end

      describe "with --max-rss" do
        def probe(total_kb)
          instance_double(ActiveMutator::MemoryProbe, system: nil,
                                                      processes: { Process.pid => { rss_kb: total_kb, hwm_kb: total_kb,
                                                                                    pss_kb: total_kb } })
        end

        def watched_runner(total_kb, **cfg)
          allow(ActiveMutator::Sampler).to receive(:new).and_wrap_original { |orig, **kw| orig.call(**kw, probe: probe(total_kb)) }
          runner = aborting_runner { [] }
          runner.instance_variable_set(:@config, config.with(max_rss: 1000, **cfg))
          runner
        end

        it "stops the run with exit 3 at the ceiling, saying so on stderr without --diagnostics" do
          runner = watched_runner(1000)
          code = nil
          expect { code = runner.call }
            .to output(/\] memory at 100% of --max-rss 1000K \(1000K\); stopping the run\n/).to_stderr_from_any_process
          expect(code).to eq(3)
          expect(summaries.last.last[:aborted]).to include(reason: :memory_ceiling)
        end

        it "warns once at 90% and lets the run finish" do
          runner = watched_runner(950)
          code = nil
          expect { code = runner.call }.to output(/\A[^\n]*\] warn memory at 95% of --max-rss 1000K \(950K\)\n\z/)
            .to_stderr_from_any_process
          expect(code).to eq(0)
        end

        it "prints the warning once with --diagnostics too" do
          allow(ActiveMutator::Baseline).to receive(:new).and_return(
            instance_double(ActiveMutator::Baseline, coverage_map: instance_double(ActiveMutator::CoverageMap))
          )
          allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
          allow(ActiveMutator::Sampler).to receive(:new).and_wrap_original { |orig, **kw| orig.call(**kw, probe: probe(950)) }

          # Built inside the block: the --diagnostics sink holds the $stderr it was built with.
          expect do
            runner = described_class.new(config.with(max_rss: 1000, diagnostics: true), reporter: reporter)
            allow(runner).to receive(:preload!)
            allow(runner).to receive(:preload_spec_helper!)
            allow(runner).to receive(:discover).and_return(discovery([]))
            runner.call
          end.to output(satisfy { |text| text.scan("warn memory at").size == 1 }).to_stderr
        end
      end

      it "lets the report finish when a signal lands during it, printing it once, then exits as aborted" do
        runner = aborting_runner { [] }
        allow(reporter).to receive(:summary).and_wrap_original do |orig, *args, **kw|
          Process.kill("TERM", Process.pid)
          sleep 0.2 # the trap runs here; it must not interrupt the report
          orig.call(*args, **kw)
        end

        expect(runner.call).to eq(143)
        expect(summaries).to eq([[[], { invalid_count: 0 }]])
        expect(abort_event).to include(reason: :sigterm)
      end

      it "exits 3 when the memory ceiling trips during the report" do
        runner = aborting_runner { [] }
        allow(reporter).to receive(:summary).and_wrap_original do |orig, *args, **kw|
          runner.instance_variable_get(:@abort).trip!(:memory_ceiling)
          orig.call(*args, **kw)
        end

        expect(runner.call).to eq(3)
        expect(summaries).to eq([[[], { invalid_count: 0 }]])
      end

      it "keeps the finished results when the flag trips as the mutating phase ends" do
        killed = ActiveMutator::Result.new(mutation: mutation, status: :killed, details: nil)
        runner = aborting_runner { [killed] }
        bus.subscribe do |e|
          next unless e.type == :phase_end && e.fields[:phase] == :mutating

          runner.instance_variable_get(:@abort).trip!(:memory_ceiling)
        end

        expect(runner.call).to eq(3)
        expect(summaries).to eq([[[killed], { invalid_count: 0,
                                              aborted: { reason: :memory_ceiling, in_flight: [], planned: 0 } }]])
      end

      it "keeps the phase-1 results when the flag trips while escalation is planned" do
        survived = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
        runner = aborting_runner { [survived] }
        allow(runner).to receive(:escalate_class_body_survivors) do |results, *|
          runner.instance_variable_get(:@abort).trip!(:sigint)
          results
        end

        expect(runner.call).to eq(130)
        expect(summaries).to eq([[[survived], { invalid_count: 0,
                                                aborted: { reason: :sigint, in_flight: [], planned: 0 } }]])
      end

      it "prints no second summary when the abort lands after the report" do
        runner = aborting_runner { [] }
        allow(runner).to receive(:exit_code) { runner.instance_variable_get(:@abort).trip!(:sigterm) }

        expect(runner.call).to eq(143)
        expect(summaries).to eq([[[], { invalid_count: 0 }]])
        expect(abort_event).to include(reason: :sigterm)
      end

      it "prints the partial summary when the flag tripped just before the report" do
        runner = aborting_runner do
          flag = runner.instance_variable_get(:@abort)
          flag.deferred { flag.trip!(:sigint) }
          []
        end

        expect(runner.call).to eq(130)
        expect(summaries).to eq([[[], { invalid_count: 0, aborted: { reason: :sigint, in_flight: [], planned: 0 } }]])
      end

      it "reports an abort before planning with no plan size and no invalid count" do
        runner = aborting_runner { [] }
        allow(runner).to receive(:preload!) do
          Process.kill("TERM", Process.pid)
          sleep 5
        end

        expect(runner.call).to eq(143)
        expect(summaries).to eq([[[], { invalid_count: 0, aborted: { reason: :sigterm, in_flight: [], planned: nil } }]])
        expect(abort_event).to include(planned: nil)
      end

      it "passes the plan's invalid count to the aborted summary" do
        runner = aborting_runner { raise ActiveMutator::Aborted, :sigint }
        analysis = instance_double(ActiveMutator::Analysis, mutations: [], invalid_count: 4)
        allow(ActiveMutator::Engine).to receive(:new).and_return(instance_double(ActiveMutator::Engine, analyze: analysis))
        allow(runner).to receive(:discover).and_return(discovery([subject_]))
        allow(runner).to receive(:plan_work).and_return([[], [], {}])

        expect(runner.call).to eq(130)
        expect(summaries.last.last).to include(invalid_count: 4)
      end
    end
  end

  it "exits 1 when mutants survive, 0 otherwise" do
    survived = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
    killed = ActiveMutator::Result.new(mutation: mutation, status: :killed, details: nil)
    expect(described_class.new(config).exit_code([killed, survived])).to eq(1)
    expect(described_class.new(config).exit_code([killed])).to eq(0)
  end

  describe "#exit_code with fail_at" do
    def result(status)
      ActiveMutator::Result.new(mutation: mutation, status: status, details: nil)
    end

    def results(**counts)
      counts.flat_map { |status, n| Array.new(n) { result(status) } }
    end

    it "exits 1 on any survivor when fail_at is nil" do
      expect(described_class.new(config).exit_code(results(killed: 99, survived: 1))).to eq(1)
    end

    it "exits 0 when the score meets the threshold exactly" do
      runner = described_class.new(config.with(fail_at: 90.0))
      expect(runner.exit_code(results(killed: 9, survived: 1))).to eq(0)
    end

    it "exits 1 when the score is below the threshold" do
      runner = described_class.new(config.with(fail_at: 90.0))
      expect(runner.exit_code(results(killed: 8, survived: 2))).to eq(1)
    end

    it "counts timeouts as detected" do
      expect(described_class.new(config).exit_code(results(timeout: 7))).to eq(0)
      runner = described_class.new(config.with(fail_at: 90.0))
      expect(runner.exit_code(results(timeout: 9, survived: 1))).to eq(0)
      expect(runner.exit_code(results(timeout: 8, survived: 2))).to eq(1)
    end

    it "exits 0 with no survivors regardless of other statuses" do
      runner = described_class.new(config.with(fail_at: 100.0))
      expect(runner.exit_code(results(uncovered: 3))).to eq(0)
    end

    it "exits 1 when mutants errored, even with no survivors" do
      expect(described_class.new(config).exit_code(results(error: 7))).to eq(1)
    end

    it "counts errors as not detected against fail_at" do
      runner = described_class.new(config.with(fail_at: 80.0))
      expect(runner.exit_code(results(error: 7))).to eq(1)
      expect(runner.exit_code(results(killed: 9, error: 1))).to eq(0)
      expect(runner.exit_code(results(killed: 7, error: 3))).to eq(1)
    end
  end

  describe "#preload_spec_helper!" do
    it "requires rails_helper when present, in preference order" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec", "rails_helper.rb"), "$rails_helper_loaded = true")
        File.write(File.join(dir, "spec", "spec_helper.rb"), "$spec_helper_loaded = true")
        runner = described_class.new(config.with(root: dir))
        runner.send(:preload_spec_helper!)
        expect($rails_helper_loaded).to be(true)
        expect($spec_helper_loaded).to be_nil
      ensure
        $rails_helper_loaded = $spec_helper_loaded = nil
      end
    end

    it "does nothing for :none" do
      runner = described_class.new(config.with(preload_helper: :none, root: "/nonexistent"))
      expect { runner.send(:preload_spec_helper!) }.not_to raise_error
    end

    it "prefers an explicitly configured helper over the defaults" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "custom_helper.rb"), "$custom_helper_loaded = true")
        File.write(File.join(dir, "spec", "spec_helper.rb"), "$default_helper_loaded = true")
        runner = described_class.new(config.with(root: dir, preload_helper: "custom_helper.rb"))
        runner.send(:preload_spec_helper!)
        expect($custom_helper_loaded).to be(true)
        expect($default_helper_loaded).to be_nil
      ensure
        $custom_helper_loaded = $default_helper_loaded = nil
        $LOAD_PATH.delete(dir)
      end
    end

    it "quietly does nothing when the configured helper does not exist" do
      Dir.mktmpdir do |dir|
        runner = described_class.new(config.with(root: dir, preload_helper: "missing_helper.rb"))
        expect { runner.send(:preload_spec_helper!) }.not_to raise_error
      end
    end

    it "requires rspec-core before loading the helper" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec", "spec_helper.rb"), "# empty")
        runner = described_class.new(config.with(root: dir))
        allow(runner).to receive(:require).and_call_original
        expect(runner).to receive(:require).with("rspec/core").and_call_original
        runner.send(:preload_spec_helper!)
      ensure
        $LOAD_PATH.delete(File.join(dir, "spec"))
      end
    end

    it "puts the helper's directory on $LOAD_PATH so bare requires resolve" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec", "rails_helper.rb"), 'require "bare_support_shim"')
        File.write(File.join(dir, "spec", "bare_support_shim.rb"), "$bare_require_worked = true")
        described_class.new(config.with(root: dir)).send(:preload_spec_helper!)
        expect($bare_require_worked).to be(true)
      ensure
        $bare_require_worked = nil
        $LOAD_PATH.delete(File.join(dir, "spec"))
      end
    end

    it "does not duplicate an already-present $LOAD_PATH entry" do
      Dir.mktmpdir do |dir|
        spec_dir = File.join(dir, "spec")
        FileUtils.mkdir_p(spec_dir)
        File.write(File.join(spec_dir, "spec_helper.rb"), "# empty")
        runner = described_class.new(config.with(root: dir))
        runner.send(:preload_spec_helper!)
        runner.send(:preload_spec_helper!)
        expect($LOAD_PATH.count(spec_dir)).to eq(1)
      ensure
        $LOAD_PATH.delete(File.join(dir, "spec"))
      end
    end

    it "disarms SimpleCov after preload" do
      fake = Class.new do
        def self.at_exit_calls = @at_exit_calls ||= []
        def self.at_exit(&blk) = at_exit_calls << blk
      end
      stub_const("SimpleCov", fake)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec", "spec_helper.rb"), "# empty")
        described_class.new(config.with(root: dir)).send(:preload_spec_helper!)
      end
      expect(fake.at_exit_calls.size).to eq(1)
    end
  end

  describe "#preload!" do
    it "requires each configured file relative to root" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "boot.rb"), "$preload_boot_loaded = true")
        described_class.new(config.with(root: dir, requires: ["boot.rb"])).send(:preload!)
        expect($preload_boot_loaded).to be(true)
      ensure
        $preload_boot_loaded = nil
      end
    end

    it "requires config/environment.rb when no requires are given" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "environment.rb"), "$preload_env_loaded = true")
        described_class.new(config.with(root: dir, requires: [])).send(:preload!)
        expect($preload_env_loaded).to be(true)
      ensure
        $preload_env_loaded = nil
      end
    end

    it "eager loads the Rails app after requiring environment.rb" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "environment.rb"), <<~RUBY)
          module Rails
            def self.application = @application ||= Object.new.tap do |app|
              def app.eager_load! = $preload_eager_loaded = true
            end
          end
        RUBY
        described_class.new(config.with(root: dir, requires: [])).send(:preload!)
        expect($preload_eager_loaded).to be(true)
      ensure
        $preload_eager_loaded = nil
        Object.send(:remove_const, :Rails) if defined?(::Rails)
      end
    end

    it "skips config/environment.rb when explicit requires are given" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "boot.rb"), "# no-op")
        File.write(File.join(dir, "config", "environment.rb"), "$preload_env_loaded = true")
        described_class.new(config.with(root: dir, requires: ["boot.rb"])).send(:preload!)
        expect($preload_env_loaded).to be_nil
      ensure
        $preload_env_loaded = nil
      end
    end
  end

  describe "#accept_survivors!" do
    it "does not touch the ledger when nothing survived" do
      ledger = instance_double(ActiveMutator::AcceptedLedger)
      expect(ledger).not_to receive(:accept!)
      killed = ActiveMutator::Result.new(mutation: mutation, status: :killed, details: nil)
      described_class.new(config).send(:accept_survivors!, ledger, [killed], { mutation => "fp" }, ["lib/a.rb"])
    end

    it "accepts surviving fingerprints into the ledger" do
      ledger = instance_double(ActiveMutator::AcceptedLedger)
      m = mutation
      survived = ActiveMutator::Result.new(mutation: m, status: :survived, details: nil)
      fingerprints = { m => "fp1" }
      expect(ledger).to receive(:accept!).with(["fp1"], ["fp1"], scanned_files: ["lib/a.rb"])
      described_class.new(config).send(:accept_survivors!, ledger, [survived], fingerprints, ["lib/a.rb"])
    end
  end

  describe "#discover" do
    it "drops files matching exclude globs during discovery" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "skip.rb"), "class Skip; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated/**"]))
        subjects = runner.send(:discover).subjects

        expect(subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "excludes nested files under a dir/** pattern" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated", "a"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "a", "deep.rb"), "class Deep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated/**"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "treats a bare directory pattern as excluding everything beneath it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated", "a"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "skip.rb"), "class Skip; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "a", "deep.rb"), "class Deep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "supports plain file globs like **/legacy/*" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "legacy"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "legacy", "old.rb"), "class Old; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["**/legacy/*"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "excludes correctly when root has a trailing slash" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")
        File.write(File.join(dir, "lib", "generated", "skip.rb"), "class Skip; def a; 1; end; end")

        runner = described_class.new(config.with(root: "#{dir}/", exclude: ["lib/generated"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "keeps files that match no exclude pattern" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, exclude: ["lib/generated"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "applies the subject_filter expression when present" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; def b; 2; end; end")

        runner = described_class.new(config.with(root: dir, subject_filter: "Keep#a"))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "returns all discovered subjects when subject_filter is nil" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; def b; 2; end; end")

        runner = described_class.new(config.with(root: dir, subject_filter: nil))
        expect(runner.send(:discover).subjects.map(&:name)).to contain_exactly("Keep#a", "Keep#b")
      end
    end

    it "discovers files in nested subdirectories" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "nested", "deeper"))
        File.write(File.join(dir, "lib", "nested", "deeper", "deep.rb"),
                   "class Deep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Deep#a"])
      end
    end

    it "scans only the configured paths when paths are given" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "custom"))
        FileUtils.mkdir_p(File.join(dir, "lib"))
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "custom", "wanted.rb"), "class Wanted; def a; 1; end; end")
        File.write(File.join(dir, "lib", "decoy.rb"), "class LibDecoy; def a; 1; end; end")
        File.write(File.join(dir, "app", "decoy.rb"), "class AppDecoy; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, paths: ["custom"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Wanted#a"])
      end
    end

    it "falls back to default app/lib paths when paths are empty" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "lib", "keep.rb"), "class LibKeep; def a; 1; end; end")
        File.write(File.join(dir, "app", "keep.rb"), "class AppKeep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, paths: []))
        expect(runner.send(:discover).subjects.map(&:name)).to contain_exactly("AppKeep#a", "LibKeep#a")
      end
    end

    it "uses a positional file path directly, yielding only that file's subjects" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "wanted.rb"), "class Wanted; def a; 1; end; end")
        File.write(File.join(dir, "lib", "decoy.rb"), "class Decoy; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, paths: ["lib/wanted.rb"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Wanted#a"])
      end
    end

    it "still globs a positional directory recursively" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "nested"))
        File.write(File.join(dir, "lib", "top.rb"), "class Top; def a; 1; end; end")
        File.write(File.join(dir, "lib", "nested", "deep.rb"), "class Deep; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, paths: ["lib"]))
        expect(runner.send(:discover).subjects.map(&:name)).to contain_exactly("Top#a", "Deep#a")
      end
    end

    it "raises for a nonexistent positional path instead of silently matching nothing" do
      Dir.mktmpdir do |dir|
        runner = described_class.new(config.with(root: dir, paths: ["app/models/typo.rb"]))
        expect { runner.send(:discover).subjects }
          .to raise_error(ActiveMutator::Error, /app\/models\/typo\.rb/)
      end
    end

    it "raises for a directly named non-Ruby file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "README.md"), "# readme")

        runner = described_class.new(config.with(root: dir, paths: ["README.md"]))
        expect { runner.send(:discover).subjects }
          .to raise_error(ActiveMutator::Error, /not a Ruby file/)
      end
    end

    it "yields each subject once when a file arg overlaps a directory arg" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "foo.rb"), "class Foo; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, paths: ["lib", "lib/foo.rb"]))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Foo#a"])
      end
    end

    it "applies exclude patterns to directly named files" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "generated"))
        File.write(File.join(dir, "lib", "generated", "skip.rb"), "class Skip; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir, paths: ["lib/generated/skip.rb"],
                                                 exclude: ["lib/generated/**"]))
        expect(runner.send(:discover).subjects).to eq([])
      end
    end

    it "wires SinceFilter when since is set and keeps only covered subjects" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; def b; 2; end; end")

        filter = instance_double(ActiveMutator::SinceFilter, changed_files: [])
        expect(ActiveMutator::SinceFilter).to receive(:new)
          .with(ref: "main", root: dir).and_return(filter)
        allow(filter).to receive(:cover?) { |s| s.name == "Keep#a" }

        runner = described_class.new(config.with(root: dir, since: "main"))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    describe "discovery facts for --allow-empty" do
      def since_filter(changed_files:, cover: ->(_s) { false })
        filter = instance_double(ActiveMutator::SinceFilter, changed_files: changed_files)
        allow(filter).to receive(:cover?) { |s| cover.call(s) }
        allow(ActiveMutator::SinceFilter).to receive(:new).and_return(filter)
      end

      def project(dir)
        FileUtils.mkdir_p(File.join(dir, "lib", "generated"))
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "lib", "a.rb"), "class A\n  X = 1\n  def a = 2\nend\n")
        File.write(File.join(dir, "lib", "generated", "g.rb"), "class G; def g; 1; end; end")
        File.write(File.join(dir, "spec", "a_spec.rb"), "RSpec.describe(A) { it { } }")
        FileUtils.mkdir_p(File.join(dir, "spec_tools"))
        File.write(File.join(dir, "spec_tools", "t.rb"), "class T; def t; 1; end; end")
      end

      it "lists root-relative scanned files after excludes, minus spec_paths" do
        Dir.mktmpdir do |dir|
          project(dir)
          runner = described_class.new(config.with(root: dir, paths: ["lib", "spec"], exclude: ["lib/generated"]))
          expect(runner.send(:discover).scanned_files).to eq(["lib/a.rb"])
        end
      end

      it "only drops files inside a spec path, not siblings sharing its prefix" do
        Dir.mktmpdir do |dir|
          project(dir)
          runner = described_class.new(config.with(root: dir, paths: ["lib", "spec", "spec_tools"],
                                                   exclude: ["lib/generated"], spec_paths: ["spec/"]))
          expect(runner.send(:discover).scanned_files).to eq(["lib/a.rb", "spec_tools/t.rb"])
        end
      end

      it "reports no since candidates without --since" do
        Dir.mktmpdir do |dir|
          project(dir)
          expect(described_class.new(config.with(root: dir)).send(:discover).since_candidates).to eq([])
        end
      end

      it "intersects the diff's files with the scanned files to get since candidates" do
        Dir.mktmpdir do |dir|
          project(dir)
          since_filter(changed_files: ["lib/a.rb", "lib/generated/g.rb", "spec/a_spec.rb", "README.md", "lib/gone.rb"])
          runner = described_class.new(config.with(root: dir, paths: ["lib", "spec"], since: "main",
                                                   exclude: ["lib/generated"]))
          expect(runner.send(:discover).since_candidates).to eq(["lib/a.rb"])
        end
      end

      it "keeps class-body subjects in since_matched_all even under --no-class-level" do
        Dir.mktmpdir do |dir|
          project(dir)
          since_filter(changed_files: ["lib/a.rb"], cover: ->(s) { s.file.end_with?("lib/a.rb") })
          runner = described_class.new(config.with(root: dir, since: "main", class_level: false))
          found = runner.send(:discover)
          expect(found.subjects.map(&:name)).to eq(["A#a"])
          expect(found.since_matched_all.map(&:kind)).to contain_exactly(:class_body, :instance)
        end
      end

      it "leaves since_matched_all empty when the filter covers nothing" do
        Dir.mktmpdir do |dir|
          project(dir)
          since_filter(changed_files: ["lib/a.rb"])
          runner = described_class.new(config.with(root: dir, since: "main"))
          found = runner.send(:discover)
          expect(found.subjects).to eq([])
          expect(found.since_matched_all).to eq([])
          expect(found.since_candidates).to eq(["lib/a.rb"])
        end
      end
    end

    it "does not instantiate SinceFilter when since is nil" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep; def a; 1; end; end")

        expect(ActiveMutator::SinceFilter).not_to receive(:new)
        runner = described_class.new(config.with(root: dir, since: nil))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "includes class-body subjects when class_level is enabled" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep\n  X = 1\n  def a = 2\nend\n")

        runner = described_class.new(config.with(root: dir, class_level: true))
        subjects = runner.send(:discover).subjects
        expect(subjects.map(&:kind)).to contain_exactly(:class_body, :instance)
      end
    end

    it "excludes class-body subjects when class_level is disabled" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "keep.rb"), "class Keep\n  X = 1\n  def a = 2\nend\n")

        runner = described_class.new(config.with(root: dir, class_level: false))
        subjects = runner.send(:discover).subjects
        expect(subjects.map(&:kind)).to eq([:instance])
        expect(subjects.map(&:name)).to eq(["Keep#a"])
      end
    end

    it "keeps concern-block def subjects when class_level is disabled" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "ticketable.rb"), <<~RUBY)
          module Ticketable
            included do
              validates :name, presence: true
              def label = "x"
            end
            class_methods do
              def build = new
            end
          end
        RUBY

        runner = described_class.new(config.with(root: dir, class_level: false))
        subjects = runner.send(:discover).subjects
        expect(subjects.map(&:name)).to eq(["Ticketable#label", "Ticketable::ClassMethods#build"])
        expect(subjects.map(&:kind)).to eq(%i[instance instance])
      end
    end

    it "sorts discovered files by path so subject order is deterministic" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "z_last.rb"), "class ZLast; def a; 1; end; end")
        File.write(File.join(dir, "lib", "a_first.rb"), "class AFirst; def a; 1; end; end")

        runner = described_class.new(config.with(root: dir))
        expect(runner.send(:discover).subjects.map(&:name)).to eq(["AFirst#a", "ZLast#a"])
      end
    end
  end

  describe "#call" do
    def stub_call_collaborators(runner, mutations)
      allow(runner).to receive(:discover).and_return(discovery([subject_]))
      analysis = ActiveMutator::Analysis.new(mutations: mutations, invalid_count: 0)
      engine = instance_double(ActiveMutator::Engine, analyze: analysis)
      allow(ActiveMutator::Engine).to receive(:new).and_return(engine)
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      allow(map).to receive(:time_for).and_return(0.1)
      baseline = instance_double(ActiveMutator::Baseline, coverage_map: map)
      allow(ActiveMutator::Baseline).to receive(:new).and_return(baseline)
    end

    it "caps mutations at max_mutants before planning" do
      Dir.mktmpdir do |dir|
        mutations = [mutation(line: 1), mutation(line: 2), mutation(line: 3)]
        cfg = config.with(root: dir, max_mutants: 2)
        reporter = instance_double(ActiveMutator::Reporter::Terminal, on_result: nil, summary: nil)
        runner = described_class.new(cfg, reporter: reporter)
        stub_call_collaborators(runner, mutations)
        scheduler = instance_double(ActiveMutator::Scheduler, run: [])
        allow(ActiveMutator::Scheduler).to receive(:new).and_return(scheduler)

        runner.call

        expect(scheduler).to have_received(:run) do |items|
          expect(items.map { |i| i.mutation.line }).to eq([1, 2])
        end
      end
    end

    it "loads custom operators before analysis" do
      Dir.mktmpdir do |dir|
        cfg = config.with(root: dir, debug_plan: true)
        runner = described_class.new(cfg)
        stub_call_collaborators(runner, [mutation(line: 1)])
        expect(runner).to receive(:load_operators)
        capture_stdout { runner.call }
      end
    end

    it "debug_plan prints planned items as JSON and returns 0 without scheduling" do
      Dir.mktmpdir do |dir|
        mutations = [mutation(line: 1), mutation(line: 2)]
        cfg = config.with(root: dir, debug_plan: true)
        runner = described_class.new(cfg)
        stub_call_collaborators(runner, mutations)
        expect(ActiveMutator::Scheduler).not_to receive(:new)

        result = nil
        output = capture_stdout { result = runner.call }

        expect(result).to eq(0)
        parsed = JSON.parse(output)
        expect(parsed["planned"].size).to eq(2)
        item = parsed["planned"].first
        expect(item.keys).to contain_exactly("subject", "description", "file", "line", "lane", "timeout", "examples")
        expect(parsed["pre_resolved"]).to eq({})
      end
    end

    describe "empty plan" do
      def run_empty(cfg, found: nil)
        reporter = instance_double(ActiveMutator::Reporter::Terminal, on_result: nil, summary: nil)
        runner = described_class.new(cfg, reporter: reporter)
        stub_call_collaborators(runner, [])
        allow(runner).to receive(:discover).and_return(found) if found
        expect(ActiveMutator::Scheduler).not_to receive(:new)
        result = nil
        stderr = capture_stderr { result = runner.call }
        [result, stderr, reporter]
      end

      it "exits 1 after an empty-plan summary when --since plans no mutants" do
        Dir.mktmpdir do |dir|
          result, stderr, reporter = run_empty(config.with(root: dir, since: "main", class_level: false))
          expect(result).to eq(1)
          expect(stderr).to include("no mutants planned (--since main matched no mutable code; " \
                                    "--no-class-level excludes class-body code)")
          expect(stderr).not_to include("--subject")
          expect(stderr).to include("--allow-empty")
          expect(reporter).to have_received(:summary).with([], invalid_count: 0, empty_plan: true)
        end
      end

      it "passes the invalid count through to the empty-plan summary" do
        Dir.mktmpdir do |dir|
          reporter = instance_double(ActiveMutator::Reporter::Terminal, on_result: nil, summary: nil)
          runner = described_class.new(config.with(root: dir, since: "main"), reporter: reporter)
          stub_call_collaborators(runner, [])
          analysis = ActiveMutator::Analysis.new(mutations: [], invalid_count: 3)
          allow(ActiveMutator::Engine).to receive(:new)
            .and_return(instance_double(ActiveMutator::Engine, analyze: analysis))
          capture_stderr { runner.call }
          expect(reporter).to have_received(:summary).with([], invalid_count: 3, empty_plan: true)
        end
      end

      it "names the --subject filter as the cause" do
        Dir.mktmpdir do |dir|
          _, stderr, = run_empty(config.with(root: dir, subject_filter: "Foo#bar"))
          expect(stderr).to include("no mutants planned (--subject Foo#bar matched no subjects)")
          expect(stderr).not_to include("--since", "--no-class-level")
        end
      end

      it "exits 0 with --allow-empty and still prints the empty-plan summary" do
        Dir.mktmpdir do |dir|
          result, stderr, reporter = run_empty(config.with(root: dir, since: "main", allow_empty: true))
          expect(result).to eq(0)
          expect(stderr).to include("no mutants planned")
          expect(reporter).to have_received(:summary).with([], invalid_count: 0, empty_plan: true)
        end
      end

      describe "--allow-empty judging the --since diff" do
        let(:lenient) { config.with(allow_empty: true, since: "main") }

        def class_body_in(dir)
          ActiveMutator::Subject.new(name: "A", file: File.join(dir, "lib", "a.rb"), byte_range: 0...10,
                                     line_range: 1..5, constant_scope: "A", kind: :class_body)
        end

        def def_in(dir) = subject_.with(file: File.join(dir, "lib", "a.rb"))

        it "exits 0 when the diff has no candidate files" do
          Dir.mktmpdir do |dir|
            result, stderr, = run_empty(lenient.with(root: dir), found: discovery([], since_candidates: []))
            expect(result).to eq(0)
            expect(stderr).not_to include("Changed:", "forgiving")
          end
        end

        it "exits 1 naming the candidate file that planned nothing" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb", "lib/b.rb"])
            result, stderr, = run_empty(lenient.with(root: dir), found: found)
            expect(result).to eq(1)
            expect(stderr).to include("--allow-empty forgives an empty plan only when no candidate source file changed")
            expect(stderr).to include("Changed: lib/a.rb, lib/b.rb")
          end
        end

        it "exits 0 when every candidate file changed only comments" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb", "lib/b.rb"], comment_only: ["lib/a.rb", "lib/b.rb"])
            result, stderr, = run_empty(lenient.with(root: dir), found: found)
            expect(result).to eq(0)
            expect(stderr).to include("forgiving empty plan: only comments changed in lib/a.rb, lib/b.rb")
            expect(stderr).not_to include("Changed:")
          end
        end

        it "exits 1 naming only the files whose code changed" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb", "lib/b.rb"], comment_only: ["lib/a.rb"])
            result, stderr, = run_empty(lenient.with(root: dir), found: found)
            expect(result).to eq(1)
            expect(stderr).to include("Changed: lib/b.rb")
            expect(stderr).not_to include("lib/a.rb")
          end
        end

        it "lets a comment-only file ride along with a --no-class-level class-body change" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb", "lib/b.rb"], comment_only: ["lib/b.rb"],
                                  since_matched_all: [class_body_in(dir)])
            result, stderr, = run_empty(lenient.with(root: dir, class_level: false), found: found)
            expect(result).to eq(0)
            expect(stderr).to include("--no-class-level")
          end
        end

        it "exits 0 under --no-class-level when only class-body subjects matched the diff" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb"], since_matched_all: [class_body_in(dir)])
            result, stderr, = run_empty(lenient.with(root: dir, class_level: false), found: found)
            expect(result).to eq(0)
            expect(stderr).to include("forgiving empty plan")
            expect(stderr).to include("--no-class-level")
          end
        end

        it "exits 1 under --no-class-level when a second candidate file matched no subject at all" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb", "lib/b.rb"], since_matched_all: [class_body_in(dir)])
            result, stderr, = run_empty(lenient.with(root: dir, class_level: false), found: found)
            expect(result).to eq(1)
            expect(stderr).to include("Changed: lib/a.rb, lib/b.rb")
            expect(stderr).not_to include("forgiving")
          end
        end

        it "exits 1 under --no-class-level when a def-level subject matched but planned nothing" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb"], since_matched_all: [class_body_in(dir), def_in(dir)])
            result, stderr, = run_empty(lenient.with(root: dir, class_level: false), found: found)
            expect(result).to eq(1)
            expect(stderr).to include("Changed: lib/a.rb")
          end
        end

        it "exits 1 under --no-class-level when a candidate changed but no subject matched" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb"], since_matched_all: [])
            result, stderr, = run_empty(lenient.with(root: dir, class_level: false), found: found)
            expect(result).to eq(1)
            expect(stderr).to include("Changed: lib/a.rb")
          end
        end

        it "exits 1 with class level on even when only class-body subjects matched" do
          Dir.mktmpdir do |dir|
            found = discovery([], since_candidates: ["lib/a.rb"], since_matched_all: [class_body_in(dir)])
            result, stderr, = run_empty(lenient.with(root: dir, class_level: true), found: found)
            expect(result).to eq(1)
            expect(stderr).to include("Changed: lib/a.rb")
          end
        end

        it "exits 0 unconditionally with --subject and no --since" do
          Dir.mktmpdir do |dir|
            cfg = config.with(root: dir, allow_empty: true, subject_filter: "Foo#bar")
            found = discovery([], since_candidates: ["lib/a.rb"])
            result, stderr, = run_empty(cfg, found: found)
            expect(result).to eq(0)
            expect(stderr).not_to include("Changed:")
          end
        end

        it "still exits 1 with the hint when --allow-empty is off, even with no candidates" do
          Dir.mktmpdir do |dir|
            result, stderr, = run_empty(config.with(root: dir, since: "main"), found: discovery([]))
            expect(result).to eq(1)
            expect(stderr).to include("pass --allow-empty")
          end
        end
      end

      it "does not build the baseline when --since plans no mutants" do
        Dir.mktmpdir do |dir|
          result, = run_empty(config.with(root: dir, since: "main", allow_empty: true))
          expect(result).to eq(0)
          expect(ActiveMutator::Baseline).not_to have_received(:new)
        end
      end

      it "does not build the baseline when --subject plans no mutants" do
        Dir.mktmpdir do |dir|
          result, = run_empty(config.with(root: dir, subject_filter: "Foo#bar"))
          expect(result).to eq(1)
          expect(ActiveMutator::Baseline).not_to have_received(:new)
        end
      end

      it "prints an empty --debug-plan without building the baseline" do
        Dir.mktmpdir do |dir|
          runner = described_class.new(config.with(root: dir, since: "main", debug_plan: true))
          stub_call_collaborators(runner, [])
          result = nil
          output = capture_stdout { result = runner.call }
          expect(result).to eq(0)
          expect(JSON.parse(output)).to eq("planned" => [], "pre_resolved" => {})
          expect(ActiveMutator::Baseline).not_to have_received(:new)
        end
      end

      it "builds the baseline exactly once when a scoped plan has mutants" do
        Dir.mktmpdir do |dir|
          reporter = instance_double(ActiveMutator::Reporter::Terminal, on_result: nil, summary: nil)
          runner = described_class.new(config.with(root: dir, since: "main"), reporter: reporter)
          stub_call_collaborators(runner, [mutation(line: 1)])
          scheduler = instance_double(ActiveMutator::Scheduler, run: [])
          allow(ActiveMutator::Scheduler).to receive(:new).and_return(scheduler)
          runner.call
          expect(ActiveMutator::Baseline).to have_received(:new).once
          expect(reporter).to have_received(:summary).with([], invalid_count: 0)
        end
      end

      it "still prints the normal summary for an empty plan without --since or --subject" do
        Dir.mktmpdir do |dir|
          reporter = instance_double(ActiveMutator::Reporter::Terminal, on_result: nil, summary: nil)
          runner = described_class.new(config.with(root: dir), reporter: reporter)
          stub_call_collaborators(runner, [])
          allow(ActiveMutator::Scheduler).to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
          expect(runner.call).to eq(0)
          expect(reporter).to have_received(:summary)
        end
      end
    end

    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end

    it "debug_plan rounds timeouts to exactly two decimals" do
      item = ActiveMutator::WorkItem.new(mutation: mutation(line: 2), example_ids: ["e1"],
                                         timeout: 1.23456, lane: :parallel)
      output = capture_stdout { described_class.new(config).send(:debug_plan, [item], []) }
      expect(JSON.parse(output)["planned"].first["timeout"]).to eq(1.23)
    end

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end
  end

  describe "acceptance integration" do
    it "pre-classifies ledger-accepted mutants and never schedules them" do
      m = mutation(line: 2)
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_for).and_return(["e1"])
      allow(map).to receive(:time_for).and_return(0.1)
      fps = ActiveMutator::Fingerprint.for_mutations([m], root: config.root)
      ledger = instance_double(ActiveMutator::AcceptedLedger)
      allow(ledger).to receive(:accepted?).with(fps[m]).and_return(true)

      runner = described_class.new(config)
      items, pre_results = runner.plan_work([m], map, ledger: ledger, fingerprints: fps)
      expect(items).to eq([])
      expect(pre_results.map(&:status)).to eq([:accepted])
    end
  end

  describe "#call" do
    let(:recording_reporter_class) do
      Class.new do
        attr_reader :events, :summary_results, :summary_invalid_count, :coverage_map

        def initialize
          @events = []
        end

        def coverage_map=(map)
          @coverage_map = map
        end

        def on_result(result)
          @events << result
        end

        def summary(results, invalid_count:)
          @summary_results = results
          @summary_invalid_count = invalid_count
        end
      end
    end

    let(:reporter) { recording_reporter_class.new }
    let(:map) { instance_double(ActiveMutator::CoverageMap, time_for: 0.1) }

    around do |ex|
      saved = ENV.to_h.slice("ACTIVE_MUTATOR", "RAILS_ENV")
      ENV.delete("ACTIVE_MUTATOR")
      ENV.delete("RAILS_ENV")
      Dir.mktmpdir do |root|
        @root = root
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def x\n    1 > 0\n  end\nend\n")
        FileUtils.mkdir_p(File.join(root, "spec"))
        File.write(File.join(root, "spec", "spec_helper.rb"), "$am_call_helper_loaded = true\n")
        # cwd inside the tmp root: these examples write a real ledger, and a
        # gate mutant that relativizes its path must not hit the repo root.
        Dir.chdir(root) { ex.run }
      end
    ensure
      ENV.delete("ACTIVE_MUTATOR")
      ENV.delete("RAILS_ENV")
      saved.each { |k, v| ENV[k] = v }
    end

    before do
      allow(ActiveMutator::Baseline)
        .to receive(:new).and_return(instance_double(ActiveMutator::Baseline, coverage_map: map))
      allow(ActiveMutator::Scheduler)
        .to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: []))
    end

    def call_runner(**overrides)
      described_class.new(config.with(root: @root, **overrides), reporter: reporter).call
    end

    it "wires the process env, preloads, injects the coverage map and reports" do
      allow(map).to receive(:examples_for).and_return([])
      code = call_runner
      expect(ENV.fetch("ACTIVE_MUTATOR")).to eq("1")
      expect(ENV.fetch("RAILS_ENV")).to eq("test")
      expect($am_call_helper_loaded).to be(true)
      expect(reporter.coverage_map).to be(map)
      expect(reporter.events).not_to be_empty
      expect(reporter.events.map(&:status).uniq).to eq([:uncovered])
      expect(reporter.summary_results).to eq(reporter.events)
      expect(reporter.summary_invalid_count).to eq(0)
      expect(code).to eq(0)
      expect(File).not_to exist(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME))
    end

    it "returns 1 when scheduled mutants survive" do
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      survived = ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)
      allow(ActiveMutator::Scheduler)
        .to receive(:new).and_return(instance_double(ActiveMutator::Scheduler, run: [survived]))
      expect(call_runner).to eq(1)
      expect(File).not_to exist(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME))
    end

    it "records survivors into the ledger with --accept-survivors" do
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      allow(ActiveMutator::Scheduler).to receive(:new) do |**|
        instance_double(ActiveMutator::Scheduler).tap do |s|
          allow(s).to receive(:run) do |items|
            items.map { |i| ActiveMutator::Result.new(mutation: i.mutation, status: :survived, details: nil) }
          end
        end
      end
      call_runner(accept_survivors: true)
      ledger_path = File.join(@root, ActiveMutator::AcceptedLedger::FILENAME)
      expect(File).to exist(ledger_path)
      expect(JSON.parse(File.read(ledger_path))).not_to be_empty
    end

    it "warns about stale accepted fingerprints" do
      allow(map).to receive(:examples_for).and_return([])
      # Stale entry inside a fully scanned file; entries in unscanned files
      # are out of scope and never warned about (#24).
      stale = { "file" => "lib/a.rb", "subject" => "Gone#away", "description" => "d",
                "original_snippet" => "x", "ordinal" => 0 }
      File.write(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME), JSON.generate([stale]))
      expect { call_runner }.to output(/stale accepted fingerprint.*Gone#away/).to_stderr
    end

    it "warns about accepted fingerprints referencing missing files" do
      allow(map).to receive(:examples_for).and_return([])
      gone = { "file" => "lib/gone.rb", "subject" => "Gone#away", "description" => "d",
               "original_snippet" => "x", "ordinal" => 0 }
      File.write(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME), JSON.generate([gone]))
      expect { call_runner }
        .to output(/accepted fingerprint references missing file: lib\/gone\.rb \(Gone#away\)/).to_stderr
    end

    it "warns about missing-file entries even on a scoped run" do
      allow(map).to receive(:examples_for).and_return([])
      gone = { "file" => "lib/gone.rb", "subject" => "Gone#away", "description" => "d",
               "original_snippet" => "x", "ordinal" => 0 }
      File.write(File.join(@root, ActiveMutator::AcceptedLedger::FILENAME), JSON.generate([gone]))
      expect { call_runner(subject_filter: "A#x") }
        .to output(/accepted fingerprint references missing file: lib\/gone\.rb/).to_stderr
    end

    describe "prune scope wiring" do
      let(:ledger) do
        instance_double(ActiveMutator::AcceptedLedger, accepted?: false, stale_entries: [],
                                                       missing_file_entries: [], accept!: nil)
      end

      before do
        allow(ActiveMutator::AcceptedLedger).to receive(:load).and_return(ledger)
        allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      end

      def surviving_scheduler!
        allow(ActiveMutator::Scheduler).to receive(:new) do |**|
          instance_double(ActiveMutator::Scheduler).tap do |s|
            allow(s).to receive(:run) do |items|
              items.map { |i| ActiveMutator::Result.new(mutation: i.mutation, status: :survived, details: nil) }
            end
          end
        end
      end

      it "passes the root-relative scanned files to accept! on an unfiltered run" do
        surviving_scheduler!
        call_runner(accept_survivors: true)
        expect(ledger).to have_received(:accept!).with(anything, anything, scanned_files: ["lib/a.rb"])
      end

      it "passes the scanned files to stale_entries on an unfiltered run" do
        call_runner
        expect(ledger).to have_received(:stale_entries).with(anything, scanned_files: ["lib/a.rb"])
      end

      it "passes scanned_files: nil when a subject filter is active" do
        surviving_scheduler!
        call_runner(accept_survivors: true, subject_filter: "A#x")
        expect(ledger).to have_received(:accept!).with(anything, anything, scanned_files: nil)
        expect(ledger).to have_received(:stale_entries).with(anything, scanned_files: nil)
      end

      it "passes scanned_files: nil when --since is active" do
        filter = instance_double(ActiveMutator::SinceFilter, cover?: true, changed_files: [])
        allow(ActiveMutator::SinceFilter).to receive(:new).and_return(filter)
        surviving_scheduler!
        call_runner(accept_survivors: true, since: "main")
        expect(ledger).to have_received(:accept!).with(anything, anything, scanned_files: nil)
        expect(ledger).to have_received(:stale_entries).with(anything, scanned_files: nil)
      end

      it "passes scanned_files: nil when max_mutants truncates the run" do
        surviving_scheduler!
        call_runner(accept_survivors: true, max_mutants: 1)
        expect(ledger).to have_received(:accept!).with(anything, anything, scanned_files: nil)
        expect(ledger).to have_received(:stale_entries).with(anything, scanned_files: nil)
      end

      # #24: --no-class-level drops class_body subjects, so the file's class-body
      # fingerprint is absent even though the file is scanned. Pruning would
      # then delete accepted class-body entries as stale.
      it "passes scanned_files: nil when --no-class-level narrows the subject set" do
        surviving_scheduler!
        call_runner(accept_survivors: true, class_level: false)
        expect(ledger).to have_received(:accept!).with(anything, anything, scanned_files: nil)
        expect(ledger).to have_received(:stale_entries).with(anything, scanned_files: nil)
      end
    end

    it "prints the plan and skips execution with --debug-plan" do
      allow(map).to receive(:examples_for).and_return(["./spec/a_spec.rb[1:1]"])
      code = nil
      out = StringIO.new
      orig = $stdout
      $stdout = out
      begin
        code = call_runner(debug_plan: true)
      ensure
        $stdout = orig
      end
      expect(code).to eq(0)
      expect(ActiveMutator::Scheduler).not_to have_received(:new)
      plan = JSON.parse(out.string)
      expect(plan["planned"]).not_to be_empty
      expect(reporter.summary_results).to be_nil
    end
  end

  describe "spec_paths threading" do
    def class_body_mutation(file)
      subject = ActiveMutator::Subject.new(
        name: "User (class body)", file: file,
        byte_range: 0...30, line_range: 1..3,
        constant_scope: "User", kind: :class_body, sclass: false
      )
      ActiveMutator::Mutation.new(
        subject: subject,
        edit: ActiveMutator::Edit.new(range: 14...18, replacement: "false",
                                      description: "replace `true` with `false`", operator: "Literal"),
        original_snippet: "true", line: 2,
        mutated_file_source: "x", mutated_def_source: "x", mutated_def_line: 1
      )
    end

    it "escalation finds referencing specs under custom spec paths" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        FileUtils.mkdir_p(File.join(root, "test"))
        File.write(File.join(root, "app/models/user.rb"),
                   "class User\n  validates :email, presence: true\nend\n")
        File.write(File.join(root, "test/signup_spec.rb"),
                   "RSpec.describe \"signup\" do\n  it { User }\nend\n")

        cfg = ActiveMutator::CLI.parse([]).with(root: root, spec_paths: ["test"])
        runner = described_class.new(cfg,
                                     reporter: instance_double(ActiveMutator::Reporter::Terminal, on_result: nil))
        m = class_body_mutation(File.join(root, "app/models/user.rb"))
        survived = ActiveMutator::Result.new(mutation: m, status: :survived, details: nil)
        map = instance_double(ActiveMutator::CoverageMap)
        allow(map).to receive(:examples_for_spec_file).with("test/signup_spec.rb")
                                                      .and_return(["./test/signup_spec.rb[1:1]"])
        allow(map).to receive(:time_for).and_return(0.1)
        scheduler = instance_double(ActiveMutator::Scheduler)
        expect(scheduler).to receive(:run) do |items|
          expect(items.size).to eq(1)
          expect(items.first.example_ids).to eq(["./test/signup_spec.rb[1:1]"])
          [ActiveMutator::Result.new(mutation: m, status: :killed, details: nil)]
        end

        results = runner.escalate_class_body_survivors([survived], scheduler, map, phase1_ids: {})
        expect(results.map(&:status)).to eq([:killed])
      end
    end

    it "builds a convention spec path under every configured spec path" do
      cfg = ActiveMutator::CLI.parse([]).with(root: "/proj", spec_paths: ["test", "spec"])
      runner = described_class.new(cfg)
      expect(runner.send(:convention_spec_rels, "/proj/lib/foo/bar.rb"))
        .to eq(["test/foo/bar_spec.rb", "spec/foo/bar_spec.rb"])
    end

    it "finds the preload helper under a custom spec path" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test"))
        File.write(File.join(root, "test/spec_helper.rb"), "$helper_loaded = true\n")
        cfg = ActiveMutator::CLI.parse([]).with(root: root, spec_paths: ["test"])
        described_class.new(cfg).send(:preload_spec_helper!)
        expect($helper_loaded).to be true
      ensure
        $helper_loaded = nil
        $LOAD_PATH.delete(File.join(root, "test"))
      end
    end
  end

  describe "plan_work with class-body mutants" do
    def class_body_mutation(file)
      subject = ActiveMutator::Subject.new(
        name: "User (class body)", file: file,
        byte_range: 0...30, line_range: 1..3,
        constant_scope: "User", kind: :class_body, sclass: false
      )
      ActiveMutator::Mutation.new(
        subject: subject,
        edit: ActiveMutator::Edit.new(range: 14...18, replacement: "false", description: "replace `true` with `false`", operator: "Literal"),
        original_snippet: "true", line: 2,
        mutated_file_source: "x", mutated_def_source: "x", mutated_def_line: 1
      )
    end

    it "plans against file-covering examples plus the convention spec file" do
      root = "/proj"
      file = "/proj/app/models/user.rb"
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_covering_file).with(file)
        .and_return(["./spec/controllers/a_spec.rb[1:1]", "./spec/workers/z_spec.rb[1:1]"])
      allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb").and_return(["./spec/models/user_spec.rb[1:1]"])
      allow(map).to receive(:time_for).and_return(0.1)
      runner = described_class.new(config.with(root: root))
      items, pre = runner.plan_work([class_body_mutation(file)], map)
      expect(pre).to be_empty
      # Union of both sets, sorted so scheduling is deterministic. The
      # convention-spec example sorts between the two file-covering ones,
      # so the ordering distinguishes sort from reverse.
      expect(items.first.example_ids).to eq(
        ["./spec/controllers/a_spec.rb[1:1]", "./spec/models/user_spec.rb[1:1]", "./spec/workers/z_spec.rb[1:1]"]
      )
    end

    it "strips a trailing slash on the root when deriving the convention spec" do
      root = "/proj/"
      file = "/proj/app/models/user.rb"
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_covering_file).with(file).and_return([])
      allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb").and_return(["./spec/models/user_spec.rb[1:1]"])
      allow(map).to receive(:time_for).and_return(0.1)
      runner = described_class.new(config.with(root: root))
      items, = runner.plan_work([class_body_mutation(file)], map)
      expect(items.first.example_ids).to eq(["./spec/models/user_spec.rb[1:1]"])
    end

    it "strips the first path segment for non-app/lib files when deriving the convention spec" do
      root = "/proj"
      file = "/proj/services/thing.rb"
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_covering_file).with(file).and_return([])
      allow(map).to receive(:examples_for_spec_file).with("spec/thing_spec.rb").and_return(["./spec/thing_spec.rb[1:1]"])
      allow(map).to receive(:time_for).and_return(0.1)
      runner = described_class.new(config.with(root: root))
      items, = runner.plan_work([class_body_mutation(file)], map)
      expect(items.first.example_ids).to eq(["./spec/thing_spec.rb[1:1]"])
    end

    it "marks a class-body mutant uncovered when both sets are empty" do
      root = "/proj"
      file = "/proj/lib/thing.rb"
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_covering_file).with(file).and_return([])
      allow(map).to receive(:examples_for_spec_file).with("spec/thing_spec.rb").and_return([])
      runner = described_class.new(config.with(root: root))
      items, pre = runner.plan_work([class_body_mutation(file)], map)
      expect(items).to be_empty
      expect(pre.map(&:status)).to eq([:uncovered])
    end
  end
end
