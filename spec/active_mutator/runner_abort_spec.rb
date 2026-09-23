require "fileutils"
require "timeout"
require "tmpdir"

# The whole abort path in a real process: a real signal (or a memory
# breach), the phase owner's poll loop, the kill, and the exit code. For
# signals the Runner runs in a fork, so the signal stays out of this process.
RSpec.describe ActiveMutator::Runner, "aborting" do
  let(:dir) { Dir.mktmpdir }
  let(:ready) { File.join(dir, "ready") }
  let(:config) do
    ActiveMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 60.0, force_baseline: false,
      root: dir, preload_helper: nil, serial_patterns: [], spec_paths: ["spec"],
      browser_boot_seconds: 15.0, accept_survivors: false, exclude: [],
      max_mutants: nil, debug_plan: false, fail_at: nil, adaptive_timeout: false,
      operators: [], class_level: true, class_level_closure_cap: 10, allow_empty: false
    )
  end
  let(:runner) do
    reporter = Object.new
    def reporter.on_result(_) = nil
    def reporter.summary(*, **) = nil
    described_class.new(config, reporter: reporter)
  end

  before do
    FileUtils.mkdir_p(File.join(dir, "spec"))
    allow(runner).to receive(:preload!)
    allow(runner).to receive(:preload_spec_helper!)
    allow(runner).to receive(:discover).and_return(
      ActiveMutator::Runner::Discovery.new(subjects: [], scanned_files: [], since_candidates: [],
                                           since_matched_all: [], since_filter: nil)
    )
  end

  after { FileUtils.rm_rf(dir) }

  # Written by the process the test waits on, once it and its own child
  # exist: "<pid> <grandchild pid>". Renamed into place so it's never half read.
  def self.announce_script(ready)
    "g = spawn('sleep', '30'); File.write('#{ready}.tmp', \"\#{Process.pid} \#{g}\"); " \
      "File.rename('#{ready}.tmp', '#{ready}'); sleep 30"
  end

  def signal_run(sig)
    pid = fork do
      $stderr.reopen(File::NULL)
      code = begin
        runner.call
      rescue Exception # rubocop:disable Lint/RescueException -- the fork must never fall back into RSpec
        99
      end
      exit!(code)
    end
    Timeout.timeout(10) { sleep 0.02 until File.exist?(ready) }
    Process.kill(sig, pid)
    Timeout.timeout(10) { Process.waitpid2(pid).last }
  ensure
    begin
      Process.kill("KILL", pid) if pid && Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD, Errno::ESRCH
      nil # already reaped
    end
  end

  # Not our children to reap: poll until the kernel drops them.
  def expect_gone(*pids)
    Timeout.timeout(5) do
      pids.each do |pid|
        loop do
          Process.kill(0, pid)
          sleep 0.02
        rescue Errno::ESRCH
          break
        end
      end
    end
  end

  it "exits 143 on SIGTERM during boot, with nothing to kill" do
    allow(runner).to receive(:preload!) do
      File.write(ready, "")
      sleep 30
    end

    expect(signal_run("TERM").exitstatus).to eq(143)
  end

  it "exits 130 on SIGINT during the baseline, killing the child's whole group" do
    allow_any_instance_of(ActiveMutator::Baseline).to receive(:rspec_command)
      .and_return(["ruby", "-e", self.class.announce_script(ready)])

    expect(signal_run("INT").exitstatus).to eq(130)
    expect_gone(*File.read(ready).split.map(&:to_i))
  end

  context "with --max-rss" do
    let(:config) { super().with(max_rss: 1024, sample_interval: 0.05) }

    it "exits 3 when the sampler thread sees a breach during the baseline, killing the child's whole group" do
      allow_any_instance_of(ActiveMutator::Baseline).to receive(:rspec_command)
        .and_return(["ruby", "-e", self.class.announce_script(ready)])
      # Over the ceiling only once the child is up, so the breach comes from
      # the sampler thread mid-baseline, not from a phase boundary.
      probe = instance_double(ActiveMutator::MemoryProbe, system: nil)
      allow(probe).to receive(:processes) do |pids|
        pids.to_h { |pid| [pid, { rss_kb: File.exist?(ready) ? 2048 : 1, hwm_kb: 1, pss_kb: nil }] }
      end
      allow(ActiveMutator::Sampler).to receive(:new).and_wrap_original { |orig, **kw| orig.call(**kw, probe: probe) }

      code = nil
      code = nil
      expect { code = Timeout.timeout(10) { runner.call } }
        .to output(/\] memory at \d+% of --max-rss 1M \(\d+M\); stopping the run\n/).to_stderr_from_any_process
      expect(code).to eq(3)
      child, grandchild = File.read(ready).split.map(&:to_i)
      # Our own child here, and the abort path doesn't wait: reaping it proves it died.
      _, status = Timeout.timeout(2) { Process.waitpid2(child) }
      expect(status.termsig).to eq(9)
      expect_gone(grandchild)
    end
  end

  it "exits 143 on SIGTERM while mutating, killing every worker's whole group" do
    subject_ = ActiveMutator::Subject.new(name: "A#x", file: File.join(dir, "lib/a.rb"), byte_range: 0...10,
                                          line_range: 1..3, constant_scope: "A", kind: :instance)
    mutation = ActiveMutator::Mutation.new(
      subject: subject_, edit: ActiveMutator::Edit.new(range: 5...6, replacement: ">=", description: "d"),
      original_snippet: ">", line: 2, mutated_file_source: "", mutated_def_source: "def x = 1", mutated_def_line: 1
    )
    item = ActiveMutator::WorkItem.new(mutation: mutation, example_ids: ["./spec/a_spec.rb[1:1]"],
                                       timeout: 60.0, lane: :parallel, variable: 0.0)
    allow(ActiveMutator::Baseline).to receive(:new).and_return(
      instance_double(ActiveMutator::Baseline, coverage_map: instance_double(ActiveMutator::CoverageMap))
    )
    allow(runner).to receive(:plan_work).and_return([[item], [], {}])
    script = self.class.announce_script(ready)
    allow(ActiveMutator::Worker).to receive(:run) { exec("ruby", "-e", script) }

    expect(signal_run("TERM").exitstatus).to eq(143)
    expect_gone(*File.read(ready).split.map(&:to_i))
  end
end
