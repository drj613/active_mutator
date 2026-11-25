require "json"
require "tempfile"
require "timeout"
require "tmpdir"

RSpec.describe ActiveMutator::Scheduler do
  def item(timeout: 5.0, lane: :parallel)
    ActiveMutator::WorkItem.new(mutation: mutation_in("/app/item.rb"), example_ids: [], timeout: timeout, lane: lane)
  end

  def mutation_in(file, name: "Foo#bar", line: 10)
    subject = ActiveMutator::Subject.new(name: name, file: file, byte_range: 0...10,
                                         line_range: 9..11, constant_scope: "Foo", kind: :instance)
    ActiveMutator::Mutation.new(
      subject: subject, original_snippet: ">", line: line,
      edit: ActiveMutator::Edit.new(range: 3...4, replacement: ">=", description: "replace > with >="),
      mutated_file_source: nil, mutated_def_source: nil, mutated_def_line: nil
    )
  end

  def scheduler(worker:, jobs: 2, on_result: nil, calibrators: nil)
    described_class.new(jobs: jobs, worker: worker, on_result: on_result, calibrators: calibrators)
  end

  # For runs whose worker outlives its budget: a scheduler that never enforces
  # the deadline (or reaps a still-running child) must fail, not hang the suite.
  def run_bounded(sched, items, seconds: 3)
    Timeout.timeout(seconds) { sched.run(items) }
  end

  # SIGKILL delivery is asynchronous; poll briefly before declaring a leak.
  def expect_process_gone(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "expected process #{pid} to be killed, but it is still alive"
      end
      sleep 0.05
    end
  end

  # Poll waitpid2 so a child that never exits fails the spec instead of hanging it.
  def wait_with_deadline(pid, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      done, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if done
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def kill_test_group(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  ensure
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def expect_descendant_stopped(pid)
    Timeout.timeout(3) do
      loop do
        begin
          Process.kill(0, pid)
          return if File.exist?("/proc/#{pid}/stat") && File.read("/proc/#{pid}/stat").split[2] == "Z"
        rescue Errno::ESRCH, Errno::ENOENT
          return
        end
        sleep 0.02
      end
    end
  end

  it "collects statuses reported by workers" do
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
    results = scheduler(worker: worker).run([item, item, item])
    expect(results.map(&:status)).to eq(%i[killed killed killed])
  end

  it "reports worker details alongside the status" do
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => "boom")) }
    results = scheduler(worker: worker).run([item])
    expect(results.first.details).to eq("boom")
  end

  it "closes the worker pipe reader after a normal finish" do
    GC.disable
    baseline = Dir.children("/dev/fd").size
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
    scheduler(worker: worker).run([item, item])
    expect(Dir.children("/dev/fd").size).to eq(baseline)
  ensure
    GC.enable
  end

  it "closes both pipe ends and the stderr tempfile when fork fails" do
    pipes = []
    allow(IO).to receive(:pipe).and_wrap_original { |orig| orig.call.tap { |pair| pipes.concat(pair) } }
    stderr_files = []
    allow(Tempfile).to receive(:new).and_wrap_original { |orig, *a| orig.call(*a).tap { |t| stderr_files << t } }
    sched = scheduler(worker: ->(_m, _e, _w) {})
    failure = Errno::EAGAIN.new("fork unavailable")
    allow(sched).to receive(:fork).and_raise(failure)

    expect { sched.run([item]) }.to raise_error { |e| expect(e).to equal(failure) }
    expect(pipes).to all(be_closed)
    expect(stderr_files.map(&:path)).to eq([nil])
  ensure
    pipes.each { |io| io.close unless io.closed? }
    stderr_files.each(&:close!)
  end

  it "closes the parent's reader copy inside the child" do
    GC.disable
    pipe_count = lambda do
      Dir.children("/dev/fd").count do |fd|
        # Skip std streams: the child reopens them to /dev/null, and they may
        # be pipes in the parent (e.g. when rspec output is piped).
        fd.to_i > 2 && File.stat("/dev/fd/#{fd}").pipe?
      rescue StandardError
        false
      end
    end
    baseline = pipe_count.call
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => pipe_count.call)) }
    results = scheduler(worker: worker).run([item])
    expect(results.first.details).to eq(baseline + 1) # writer only; inherited reader closed
  ensure
    GC.enable
  end

  it "puts each worker in its own process group so a group kill reaps grandchildren" do
    worker = lambda do |_m, _e, writer|
      status = Process.getpgrp == Process.pid ? "killed" : "survived"
      writer.puts(JSON.generate("status" => status, "details" => nil))
    end
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:killed])
  end

  it "silences worker stdout and stderr so app noise cannot corrupt the parent's streams" do
    Dir.mktmpdir do |dir|
      out_path = File.join(dir, "out")
      err_path = File.join(dir, "err")
      orig_out = $stdout.dup
      orig_err = $stderr.dup
      begin
        $stdout.reopen(out_path, "w")
        $stderr.reopen(err_path, "w")
        worker = lambda do |_m, _e, writer|
          $stdout.puts "LEAK-STDOUT"
          $stderr.puts "LEAK-STDERR"
          $stdout.flush
          $stderr.flush
          writer.puts(JSON.generate("status" => "killed", "details" => nil))
        end
        scheduler(worker: worker).run([item])
      ensure
        $stdout.reopen(orig_out)
        $stderr.reopen(orig_err)
      end
      # Assert the sentinels' absence rather than emptiness: unrelated Ruby
      # warnings on stderr must not flake this spec.
      expect(File.read(out_path)).not_to include("LEAK-STDOUT")
      expect(File.read(err_path)).not_to include("LEAK-STDERR")
    end
  end

  it "flushes buffered worker output by closing the writer in the child" do
    worker = lambda do |_m, _e, writer|
      writer.sync = false
      writer.write(JSON.generate("status" => "killed", "details" => nil))
    end
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:killed]) # exit! without close would drop the buffer
  end

  it "drains reports larger than the pipe buffer while the worker is still running" do
    details = "x" * 200_000
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => details)) }
    results = run_bounded(scheduler(worker: worker), [item(timeout: 0.5)])
    expect(results.first.status).to eq(:killed)
    expect(results.first.details).to eq(details)
  end

  it "keeps the verdict of a worker that exits with a descendant holding its writer open, and stops the descendant" do
    Dir.mktmpdir do |dir|
      pids_path = File.join(dir, "pids")
      worker = lambda do |_m, _e, writer|
        parent = Process.pid
        fork do
          File.write(pids_path, "#{parent} #{Process.pid}")
          sleep 30
          Process.exit!(0)
        end
        writer.puts(JSON.generate("status" => "survived", "details" => nil))
      end
      sched = described_class.new(jobs: 2, worker: worker, term_grace: 0.3)
      results = run_bounded(sched, [item(timeout: 30)])
      expect(results.map(&:status)).to eq([:survived])
      expect_descendant_stopped(File.read(pids_path).split.last.to_i)
    ensure
      kill_test_group(File.read(pids_path).split.first.to_i) if File.exist?(pids_path)
    end
  end

  it "keeps the verdict of a worker that reports and closes its writer without exiting, and stops it" do
    Dir.mktmpdir do |dir|
      pid_path = File.join(dir, "pid")
      worker = lambda do |_m, _e, writer|
        File.write(pid_path, Process.pid.to_s)
        writer.puts(JSON.generate("status" => "killed", "details" => nil))
        writer.close
        sleep 30
      end
      results = run_bounded(described_class.new(jobs: 2, worker: worker, term_grace: 0.3), [item(timeout: 30)])
      expect(results.map(&:status)).to eq([:killed])
      pid = File.read(pid_path).to_i
      expect_process_gone(pid)
      expect { Process.waitpid(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    ensure
      kill_test_group(File.read(pid_path).to_i) if File.exist?(pid_path)
    end
  end

  it "runs at_exit hooks the worker registers, so a test's own cleanup still happens" do
    Dir.mktmpdir do |dir|
      flag = File.join(dir, "flag")
      worker = lambda do |_m, _e, writer|
        at_exit { File.write(flag, "ran") }
        writer.puts(JSON.generate("status" => "killed", "details" => nil))
      end
      results = scheduler(worker: worker).run([item])
      expect(results.map(&:status)).to eq([:killed])
      expect(File.read(flag)).to eq("ran")
    end
  end

  it "keeps the error of a worker that raises in the stderr tail" do
    worker = ->(_m, _e, _writer) { raise "boom from the worker" }
    result = scheduler(worker: worker).run([item]).first
    expect(result.status).to eq(:error)
    expect(result.details).to include("worker exited without reporting", "boom from the worker (RuntimeError)")
  end

  it "prints nothing for a worker that calls exit" do
    worker = ->(_m, _e, _writer) { exit(3) }
    expect(scheduler(worker: worker).run([item]).first.details).to eq("worker exited without reporting")
  end

  it "skips at_exit hooks inherited from the parent" do
    Dir.mktmpdir do |dir|
      flag = File.join(dir, "flag")
      test_pid = Process.pid
      armed = true
      # Registered in this process, so the run happens here, where coverage
      # sees it. The hook never fires here, and forks made after this test
      # inherit armed = false.
      at_exit { File.write(flag, "ran") if armed && Process.pid != test_pid }
      worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
      expect(scheduler(worker: worker).run([item]).map(&:status)).to eq([:killed])
      expect(File.exist?(flag)).to be(false)
    ensure
      armed = false
    end
  end

  it "falls back to a direct SIGKILL when the worker has no process group of its own" do
    pid = fork { sleep 30 }
    sched = scheduler(worker: ->(_m, _e, _w) {})
    expect { sched.send(:kill, pid) }.not_to raise_error
    expect_process_gone(pid)
  ensure
    begin
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue StandardError
      nil
    end
  end

  describe "aborting" do
    let(:flag) { ActiveMutator::AbortFlag.new }
    let(:mutation) do
      subject = ActiveMutator::Subject.new(name: "Foo#bar", file: "/app/foo.rb", byte_range: 0...10,
                                           line_range: 9..11, constant_scope: "Foo", kind: :instance)
      ActiveMutator::Mutation.new(
        subject: subject, original_snippet: ">", line: 10,
        edit: ActiveMutator::Edit.new(range: 3...4, replacement: ">=", description: "replace > with >="),
        mutated_file_source: nil, mutated_def_source: nil, mutated_def_line: nil
      )
    end

    def work(timeout: 30.0) = ActiveMutator::WorkItem.new(mutation: mutation, example_ids: [], timeout: timeout, lane: :parallel)

    it "kills every running worker at once and raises with the finished results and the in-flight list" do
      Dir.mktmpdir do |dir|
        worker = lambda do |_m, _e, writer|
          n = Dir.children(dir).size
          File.write(File.join(dir, Process.pid.to_s), "")
          next writer.puts(JSON.generate("status" => "killed", "details" => nil)) if n.zero?

          sleep 30
        end
        readers = []
        allow(IO).to receive(:pipe).and_wrap_original { |orig| orig.call.tap { |r, _| readers << r } }
        stderr_files = []
        allow(Tempfile).to receive(:new).and_wrap_original { |orig, *a| orig.call(*a).tap { |t| stderr_files << t } }
        sched = described_class.new(jobs: 1, worker: worker, abort: flag)
        tripper = Thread.new do
          sleep 0.02 until Dir.children(dir).size >= 2
          flag.trip!(:sigterm)
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        error = nil
        begin
          Timeout.timeout(5) { sched.run([work, work, work]) }
        rescue ActiveMutator::Aborted => e
          error = e
        end
        tripper.join

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
        expect(error.reason).to eq(:sigterm)
        expect(error.results.map(&:status)).to eq([:killed])
        sleeper = Dir.children(dir).map(&:to_i).max_by { |pid| File.mtime(File.join(dir, pid.to_s)) }
        expect(error.in_flight).to eq([{ seq: 2, pid: sleeper, subject: "Foo#bar", file: "/app/foo.rb", line: 10,
                                         description: "replace > with >=" }])
        # Killed but not waited for (the abort path doesn't wait): reaping it
        # now proves it died.
        _, status = Timeout.timeout(2) { Process.waitpid2(sleeper) }
        expect(status.termsig).to eq(9)
        expect(readers.size).to eq(2)
        expect(readers).to all(be_closed)
        expect(stderr_files.map(&:path)).to eq([nil, nil]) # deleted, not left for GC
      end
    end

    it "stops filling the pool when the flag trips between two spawns" do
      sched = described_class.new(jobs: 3, worker: ->(_m, _e, _w) { sleep 30 }, abort: flag)
      allow(sched).to receive(:spawn).and_wrap_original do |orig, *args|
        orig.call(*args).tap { flag.trip!(:sigterm) }
      end

      expect { Timeout.timeout(5) { sched.run([work, work, work]) } }
        .to raise_error(ActiveMutator::Aborted) { |e| expect(e.in_flight.size).to eq(1) }
      expect(sched).to have_received(:spawn).once
    end

    it "spawns nothing when the flag tripped before the run" do
      flag.deferred { flag.trip!(:sigint) }
      spawned = false
      sched = described_class.new(jobs: 1, worker: ->(_m, _e, _w) { spawned = true }, abort: flag)
      expect { sched.run([work]) }.to raise_error(ActiveMutator::Aborted, /sigint/)
      expect(spawned).to be(false)
    end

    %i[sigterm memory_ceiling].each do |reason|
      it "honors #{reason} after an exited worker leaves its writer open in a descendant" do
        Dir.mktmpdir do |dir|
          pids_path = File.join(dir, "pids")
          worker = lambda do |_m, _e, writer|
            parent = Process.pid
            fork do
              File.write(pids_path, "#{parent} #{Process.pid}")
              sleep 30
              Process.exit!(0)
            end
            writer.puts(JSON.generate("status" => "killed", "details" => nil))
          end
          previous = trap("TERM") { flag.trip!(:sigterm) } if reason == :sigterm
          tripper = Thread.new do
            Timeout.timeout(2) do
              sleep 0.02 until File.exist?(pids_path)
              worker_pid = File.read(pids_path).split.first.to_i
              loop do
                begin
                  Process.kill(0, worker_pid)
                rescue Errno::ESRCH
                  break
                end
                sleep 0.02
              end
            end
            reason == :sigterm ? Process.kill("TERM", Process.pid) : flag.trip!(reason)
          end
          error = nil
          expect do
            run_bounded(described_class.new(jobs: 1, worker: worker, abort: flag), [work])
          end.to raise_error(ActiveMutator::Aborted) { |e| error = e }
          tripper.join
          descendant = File.read(pids_path).split.last.to_i
          expect(error.reason).to eq(reason)
          # It reported before it exited, so its verdict is final.
          expect(error.results.map(&:status)).to eq([:killed])
          expect(error.in_flight).to be_empty
          expect_descendant_stopped(descendant)
        ensure
          tripper&.kill&.join
          trap("TERM", previous) if reason == :sigterm
          kill_test_group(File.read(pids_path).split.first.to_i) if File.exist?(pids_path)
        end
      end
    end
  end

  it "aborts and kills workers when the parent is orphaned" do
    checks = 0
    orphaned = -> { (checks += 1) > 1 } # healthy on the first tick, orphaned after
    worker = ->(_m, _e, _w) { sleep 30 }
    sched = described_class.new(jobs: 2, worker: worker, orphaned: orphaned)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { run_bounded(sched, [item, item, item]) }
      .to raise_error(ActiveMutator::Scheduler::OrphanedError, /parent process died/)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 5 # workers were killed, not waited out
  end

  it "runs normally when its parent is already pid 1 at start, as a detached run's is" do
    allow(Process).to receive(:ppid).and_return(1)
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
    results = described_class.new(jobs: 1, worker: worker).run([item])
    expect(results.map(&:status)).to eq([:killed])
  end

  it "aborts by default once its parent changes" do
    allow(Process).to receive(:ppid).and_return(4242)
    worker = ->(_m, _e, _w) { sleep 30 }
    sched = described_class.new(jobs: 1, worker: worker)
    allow(Process).to receive(:ppid).and_return(1)
    expect { run_bounded(sched, [item]) }.to raise_error(ActiveMutator::Scheduler::OrphanedError)
  end

  it "leaves no live worker processes behind after an orphaned abort" do
    Tempfile.create("pids") do |file|
      pid_file = file.path
      worker = lambda do |_m, _e, _w|
        File.open(pid_file, "a") { |f| f.flock(File::LOCK_EX); f.puts(Process.pid) }
        sleep 30
      end
      orphaned = lambda do
        GC.start
        File.read(pid_file).lines.size >= 2 # both workers running
      end
      sched = described_class.new(jobs: 2, worker: worker, orphaned: orphaned)
      expect { run_bounded(sched, [item, item]) }
        .to raise_error(ActiveMutator::Scheduler::OrphanedError)
      pids = File.readlines(pid_file).map(&:to_i)
      expect(pids.size).to eq(2)
      pids.each { |pid| expect_process_gone(pid) }
    end
  end

  it "marks payloads missing a status key as :error instead of crashing" do
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("details" => nil)) }
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:error])
    expect(results.first.details).to eq("worker exited without reporting")
  end

  it "marks valid JSON with a non-Hash root as :error instead of crashing" do
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate([1])) }
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:error])
    expect(results.first.details).to eq("worker exited without reporting")
  end

  it "marks unparseable payloads as :error instead of crashing" do
    worker = ->(_m, _e, writer) { writer.puts("not json{") }
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:error])
    expect(results.first.details).to eq("worker emitted unparseable payload")
  end

  it "marks silent crashes as :error" do
    worker = ->(_m, _e, _w) { Process.exit!(1) }
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:error])
    expect(results.first.details).to eq("worker exited without reporting")
  end

  it "attaches the last 20 lines of the child's stderr when it dies without reporting" do
    worker = lambda do |_m, _e, _w|
      25.times { |i| $stderr.puts "line #{i}" }
      $stderr.puts "[BUG] Segmentation fault"
      $stderr.flush
      Process.exit!(1)
    end
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:error])
    details = results.first.details
    expect(details).to start_with("worker exited without reporting; stderr tail:\n")
    expect(details).to end_with("[BUG] Segmentation fault")
    expect(details).to include("line 24")
    expect(details).not_to include("line 5\n")
  end

  it "does not clutter a reported result with the child's stderr" do
    worker = lambda do |_m, _e, writer|
      $stderr.puts "noise"
      writer.puts(JSON.generate("status" => "killed", "details" => nil))
    end
    results = scheduler(worker: worker).run([item])
    expect(results.first.details).to be_nil
  end

  it "disables libpq GSS encryption in the child unless the caller set it" do
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => ENV.fetch("PGGSSENCMODE"))) }
    original = ENV.delete("PGGSSENCMODE")
    begin
      expect(scheduler(worker: worker).run([item]).first.details).to eq("disable")
      ENV["PGGSSENCMODE"] = "prefer"
      expect(scheduler(worker: worker).run([item]).first.details).to eq("prefer")
    ensure
      original ? ENV["PGGSSENCMODE"] = original : ENV.delete("PGGSSENCMODE")
    end
  end

  it "kills over-deadline workers and marks :timeout" do
    worker = ->(_m, _e, _w) { sleep 30 }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = run_bounded(scheduler(worker: worker), [item(timeout: 0.2)])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(results.map(&:status)).to eq([:timeout])
    expect(results.first.details).to match(/\Atimed out after \d+\.\ds \(budget 0\.2s\)\z/)
    expect(elapsed).to be < 5
  end

  describe "the TERM grace before a timed-out worker is killed" do
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    it "lets the worker run its own at_exit cleanup, even under an inherited TERM trap" do
      previous = trap("TERM") {} # like the Runner's trap, which forks inherit
      begin
        Dir.mktmpdir do |dir|
          marker = File.join(dir, "cleaned")
          worker = lambda do |_m, _e, _w|
            at_exit { File.write(marker, "yes") }
            sleep 30
          end
          results = run_bounded(scheduler(worker: worker), [item(timeout: 0.2)])
          expect(results.map(&:status)).to eq([:timeout])
          expect(File.read(marker)).to eq("yes")
        end
      ensure
        trap("TERM", previous)
      end
    end

    it "kills a worker that ignores TERM once the grace runs out, timed from the deadline" do
      Tempfile.create("pid") do |file|
        worker = lambda do |_m, _e, _w|
          trap("TERM") {}
          File.write(file.path, Process.pid.to_s)
          sleep 30
        end
        started = now
        results = run_bounded(described_class.new(jobs: 1, worker: worker, term_grace: 0.5), [item(timeout: 0.2)])
        expect(now - started).to be >= 0.7
        expect(results.map(&:status)).to eq([:timeout])
        expect(results.first.details).to match(/\Atimed out after 0\.[2-4]s \(budget 0\.2s\)\z/)
        expect_process_gone(File.read(file.path).to_i)
      end
    end

    # Once the report line is in, the verdict is final; only at_exit hooks
    # (a coverage report, a server shutdown) or descendants are left, and
    # they get the grace, not the rest of the budget.
    describe "after the worker has reported" do
      def lingering(status)
        lambda do |_m, _e, writer|
          at_exit { sleep 30 }
          writer.puts(JSON.generate("status" => status, "details" => nil))
        end
      end

      it "keeps the reported verdict when the hooks run past the deadline" do
        sched = described_class.new(jobs: 1, worker: lingering("survived"), term_grace: 0.3)
        results = run_bounded(sched, [item(timeout: 0.2)])
        expect(results.map { |r| [r.status, r.details] }).to eq([[:survived, nil]])
      end

      it "stops the hooks once the grace runs out, whatever budget is left, timing the mutant to its report" do
        sched = described_class.new(jobs: 1, worker: lingering("killed"), term_grace: 0.5)
        started = now
        results = run_bounded(sched, [item(timeout: 30)])
        expect(now - started).to be_between(0.5, 2.5)
        expect(results.map(&:status)).to eq([:killed])
        expect(results.first.seconds).to be < 0.5
      end

      it "stops a worker that ignores TERM in its hooks, still with its verdict" do
        worker = lambda do |_m, _e, writer|
          at_exit do
            trap("TERM") {}
            sleep 30
          end
          writer.puts(JSON.generate("status" => "survived", "details" => nil))
        end
        sched = described_class.new(jobs: 1, worker: worker, term_grace: 0.3)
        expect(run_bounded(sched, [item(timeout: 30)]).map(&:status)).to eq([:survived])
      end

      it "does not take a half-written report for a verdict" do
        worker = lambda do |_m, _e, writer|
          writer.write('{"status":"survived"')
          writer.flush
          sleep 30
        end
        sched = described_class.new(jobs: 1, worker: worker, term_grace: 0.3)
        expect(run_bounded(sched, [item(timeout: 0.6)]).map(&:status)).to eq([:timeout])
      end

      it "records a reported kill with the calibrator" do
        calibrator = instance_double(ActiveMutator::TimeoutCalibrator, budget_for: 30.0, scale: 1.0, warmed?: false)
        allow(calibrator).to receive(:record)
        sched = described_class.new(jobs: 1, worker: lingering("killed"), term_grace: 0.3,
                                    calibrators: { parallel: calibrator })
        run_bounded(sched, [item(timeout: 30)])
        expect(calibrator).to have_received(:record).with(be < 0.3, 30.0)
      end

      it "keeps the reported verdict when an abort lands during the grace" do
        flag = ActiveMutator::AbortFlag.new
        sched = described_class.new(jobs: 1, worker: lingering("survived"), term_grace: 30, abort: flag)
        pid = nil
        allow(sched).to receive(:reap).and_wrap_original do |orig, running, results|
          pid ||= running.keys.first
          orig.call(running, results).tap do
            flag.trip!(:sigterm) if running.values.any? { |entry| entry[:reported_at] }
          end
        end
        error = nil
        expect { run_bounded(sched, [item(timeout: 30)]) }.to raise_error(ActiveMutator::Aborted) { |e| error = e }
        expect(error.results.map(&:status)).to eq([:survived])
        expect(error.in_flight).to eq([])
      ensure
        # The abort path killed it without waiting; reap it here.
        Timeout.timeout(2) { Process.waitpid(pid) } if pid
      end
    end

    it "keeps the timeout verdict when an abort lands during the grace" do
      flag = ActiveMutator::AbortFlag.new
      worker = lambda do |_m, _e, _w|
        trap("TERM") {}
        sleep 30
      end
      sched = described_class.new(jobs: 1, worker: worker, term_grace: 30, abort: flag)
      pid = nil
      allow(sched).to receive(:signal_group).and_wrap_original do |orig, target, *sig|
        pid ||= target
        orig.call(target, *sig).tap { flag.trip!(:sigterm) if sig == ["TERM"] }
      end
      error = nil
      expect { run_bounded(sched, [item(timeout: 0.2)]) }.to raise_error(ActiveMutator::Aborted) { |e| error = e }
      expect(error.results.map(&:status)).to eq([:timeout])
      expect(error.in_flight).to eq([])
    ensure
      # The abort path killed it without waiting; reap it here.
      Timeout.timeout(2) { Process.waitpid(pid) } if pid
    end
  end

  it "actually kills the timed-out worker process and closes its pipe" do
    Tempfile.create("pid") do |file|
      GC.start
      GC.disable
      pid_file = file.path
      baseline = Dir.children("/dev/fd").size
      worker = lambda do |_m, _e, _w|
        File.write(pid_file, Process.pid.to_s)
        sleep 30
      end
      results = run_bounded(scheduler(worker: worker, on_result: ->(_) { GC.start }), [item(timeout: 0.3)])
      expect(results.map(&:status)).to eq([:timeout])
      pid = File.read(pid_file).to_i
      expect(pid).to be > 0
      expect_process_gone(pid)
      expect(Dir.children("/dev/fd").size).to eq(baseline)
    ensure
      GC.enable
      leaked = File.read(pid_file).to_i
      begin
        # Cleanup if the mutant leaked it. An empty pid file reads as 0, and
        # kill(0) would signal our own process group.
        Process.kill("KILL", leaked) if leaked.positive?
      rescue StandardError
        nil
      end
    end
  end

  it "invokes on_result as each result lands" do
    seen = []
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "survived", "details" => nil)) }
    scheduler(worker: worker, on_result: ->(r) { seen << r.status }).run([item, item])
    expect(seen).to eq(%i[survived survived])
  end

  it "respects the jobs cap" do
    worker = lambda do |_m, _e, writer|
      sleep 0.15
      writer.puts(JSON.generate("status" => "killed", "details" => nil))
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    scheduler(worker: worker, jobs: 2).run([item, item, item, item])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be >= 0.3 # 4 items / 2 jobs => at least two waves
  end

  describe "events" do
    let(:mutation) do
      subject = ActiveMutator::Subject.new(name: "Foo#bar", file: "/app/models/foo.rb", byte_range: 0...10,
                                           line_range: 9..11, constant_scope: "Foo", kind: :instance)
      ActiveMutator::Mutation.new(
        subject: subject, original_snippet: ">", line: 10,
        edit: ActiveMutator::Edit.new(range: 3...4, replacement: ">=", description: "replace > with >="),
        mutated_file_source: nil, mutated_def_source: nil, mutated_def_line: nil
      )
    end
    let(:events) { [] }
    let(:bus) { ActiveMutator::Events.new.subscribe { |e| events << e } }

    def work(timeout: 5.0, lane: :parallel)
      ActiveMutator::WorkItem.new(mutation: mutation, example_ids: %w[a b], timeout: timeout, lane: lane)
    end

    it "emits mutant_start with the pid and plan, and mutant_end with status, time, and peak" do
      allow(ActiveMutator::MemoryProbe).to receive(:peak_rss_kb).and_return(812) # inherited by the fork
      worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
      results = described_class.new(jobs: 1, worker: worker, events: bus).run([work])

      start, finish = events
      expect(start.type).to eq(:mutant_start)
      expect(start.fields.except(:pid))
        .to eq(seq: 1, lane: :parallel, budget: 5.0, examples: 2, subject: "Foo#bar",
               file: "/app/models/foo.rb", line: 10, description: "replace > with >=")
      expect(start.fields[:pid]).to be_a(Integer).and(be > 0)
      expect(finish.type).to eq(:mutant_end)
      expect(finish.fields.except(:seconds))
        .to eq(seq: 1, pid: start.fields[:pid], status: :killed, peak_rss_kb: 812)
      expect(finish.fields[:seconds]).to be_a(Float).and(be >= 0)
      expect(results.first.to_h.slice(:seconds, :peak_rss_kb)).to eq(seconds: finish.fields[:seconds], peak_rss_kb: 812)
    end

    it "numbers mutants from first_seq on" do
      worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
      described_class.new(jobs: 1, worker: worker, events: bus, first_seq: 7).run([work, work])

      expect(events.select { |e| e.type == :mutant_start }.map { |e| e.fields[:seq] }).to eq([7, 8])
    end

    it "emits mutant_end for a timed-out worker" do
      sched = described_class.new(jobs: 1, worker: ->(_m, _e, _w) { sleep 30 }, events: bus)
      results = run_bounded(sched, [work(timeout: 0.2)])

      finish = events.last
      expect(finish.fields.slice(:seq, :status, :peak_rss_kb)).to eq(seq: 1, status: :timeout, peak_rss_kb: nil)
      expect(finish.fields[:seconds]).to be >= 0.2
      expect(results.first.seconds).to eq(finish.fields[:seconds])
    end

    it "carries the elapsed time on an unparseable payload" do
      worker = ->(_m, _e, writer) { writer.puts("{nope") }
      results = described_class.new(jobs: 1, worker: worker, events: bus).run([work])

      expect(results.first.seconds).to be_a(Float)
      expect(events.last.fields.slice(:status, :seconds)).to eq(status: :error, seconds: results.first.seconds)
    end

    it "leaves the peak nil where the worker cannot read it (off Linux)" do
      allow(ActiveMutator::MemoryProbe).to receive(:peak_rss_kb).and_return(nil)
      worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "survived", "details" => nil)) }
      results = described_class.new(jobs: 1, worker: worker, events: bus).run([work])

      expect(results.first.peak_rss_kb).to be_nil
    end

    it "kills and reaps workers and closes their resources when the NDJSON sink fails" do
      output = double("full filesystem", :sync= => nil)
      failure = Errno::ENOSPC.new("events disk full")
      allow(output).to receive(:write).and_raise(failure)
      pid = nil
      bus.subscribe { |event| pid = event.fields[:pid] if event.type == :mutant_start }
      bus.subscribe(ActiveMutator::Diagnostics::Ndjson.new(output))
      readers = []
      allow(IO).to receive(:pipe).and_wrap_original { |orig| orig.call.tap { |r, _| readers << r } }
      stderr_files = []
      allow(Tempfile).to receive(:new).and_wrap_original { |orig, *a| orig.call(*a).tap { |t| stderr_files << t } }
      sched = described_class.new(jobs: 1, events: bus, worker: ->(_m, _e, _w) { sleep 30 })

      expect { run_bounded(sched, [work]) }.to raise_error { |e| expect(e).to equal(failure) }
      expect(pid).to be > 0
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      expect { Process.waitpid(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
      expect(readers).to all(be_closed)
      expect(stderr_files.map(&:path)).to eq([nil])
    ensure
      kill_test_group(pid) if pid
    end

    it "cleans up the finished entry and other workers when the NDJSON sink fails at mutant_end" do
      failure = Errno::ENOSPC.new("events disk full")
      output = double("full filesystem", :sync= => nil)
      allow(output).to receive(:write) do |line|
        raise failure if JSON.parse(line)["event"] == "mutant_end"

        line.bytesize
      end
      bus.subscribe(ActiveMutator::Diagnostics::Ndjson.new(output))
      worker = lambda do |_m, ids, writer|
        sleep(ids == ["slow"] ? 30 : 0.1)
        writer.puts(JSON.generate("status" => "killed", "details" => nil))
      end
      slow = ActiveMutator::WorkItem.new(mutation: mutation, example_ids: ["slow"], timeout: 5, lane: :parallel)
      readers = []
      allow(IO).to receive(:pipe).and_wrap_original { |orig| orig.call.tap { |r, _| readers << r } }
      stderr_files = []
      allow(Tempfile).to receive(:new).and_wrap_original { |orig, *a| orig.call(*a).tap { |t| stderr_files << t } }
      sched = described_class.new(jobs: 2, events: bus, worker: worker)

      expect { run_bounded(sched, [work, slow]) }.to raise_error { |e| expect(e).to equal(failure) }
      pids = events.select { |e| e.type == :mutant_start }.map { |e| e.fields[:pid] }
      expect(pids.size).to eq(2)
      pids.each { |pid| expect_process_gone(pid) }
      expect(readers).to all(be_closed)
      expect(stderr_files.map(&:path)).to eq([nil, nil])
    ensure
      events.select { |e| e.type == :mutant_start }.each { |e| kill_test_group(e.fields[:pid]) }
    end
  end

  describe "adaptive timeouts" do
    def fake_calibrator(budget: nil, scale: 1.0, warmed: false)
      cal = instance_double(ActiveMutator::TimeoutCalibrator,
                            scale: scale, warmed?: warmed)
      if budget
        allow(cal).to receive(:budget_for).and_return(budget)
      else
        allow(cal).to receive(:budget_for) { |i| i.timeout }
      end
      allow(cal).to receive(:record)
      cal
    end

    def killed_worker
      ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
    end

    it "asks the lane's calibrator for the effective budget at spawn time" do
      # Static timeout is generous, but the calibrator returns a tiny budget:
      # the sleeping worker must be reaped as a timeout.
      cal = fake_calibrator(budget: 0.2)
      worker = ->(_m, _e, _w) { sleep 30 }
      results = run_bounded(scheduler(worker: worker, calibrators: { parallel: cal, serial: cal }),
                            [item(timeout: 60.0)])
      expect(results.map(&:status)).to eq([:timeout])
    end

    it "records killed forks with their elapsed time AND the effective budget they ran under" do
      recordings = []
      cal = fake_calibrator(budget: 5.0)
      allow(cal).to receive(:record) { |elapsed, budget| recordings << [elapsed, budget] }
      scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal })
        .run([item(timeout: 60.0), item(timeout: 60.0)])
      expect(recordings.size).to eq(2)
      # The denominator is the scaled budget (5.0), never the static 60.0 —
      # recording against the static budget would ratchet the scale to max.
      expect(recordings).to all(satisfy { |(elapsed, budget)| elapsed.positive? && budget == 5.0 })
    end

    it "routes recordings to the calibrator of the item's lane" do
      parallel_cal = fake_calibrator
      serial_cal = fake_calibrator
      scheduler(worker: killed_worker, calibrators: { parallel: parallel_cal, serial: serial_cal })
        .run([item(lane: :parallel), item(lane: :serial)])
      expect(parallel_cal).to have_received(:record).once
      expect(serial_cal).to have_received(:record).once
    end

    it "does not record survived or errored forks (they would bias the median)" do
      cal = fake_calibrator
      survived = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "survived", "details" => nil)) }
      errored  = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "error", "details" => "boom")) }
      scheduler(worker: survived, calibrators: { parallel: cal, serial: cal }).run([item])
      scheduler(worker: errored, calibrators: { parallel: cal, serial: cal }).run([item])
      expect(cal).not_to have_received(:record)
    end

    it "does not record timed-out forks (their true wall time is unknown)" do
      cal = fake_calibrator(budget: 0.2)
      worker = ->(_m, _e, _w) { sleep 30 }
      run_bounded(scheduler(worker: worker, calibrators: { parallel: cal, serial: cal }), [item(timeout: 60.0)])
      expect(cal).not_to have_received(:record)
    end

    it "runs on static budgets when no calibrators are given" do
      worker = ->(_m, _e, _w) { sleep 30 }
      results = run_bounded(scheduler(worker: worker), [item(timeout: 0.2)])
      expect(results.map(&:status)).to eq([:timeout])
    end

    it "logs the scale with its lane to stderr once per change, not once per spawn" do
      # 2.456 distinguishes round(2) from round(3): the log must read 2.46.
      cal = fake_calibrator(warmed: true, scale: 2.456)
      expect do
        scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal })
          .run([item, item, item])
      end.to output(/active_mutator: adaptive timeout scale \(parallel\): 2\.46\n/).to_stderr_from_any_process
      # exactly once: the regex above plus a negative count check
      expect do
        scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal })
          .run([item, item])
      end.to output(satisfy { |s| s.scan("adaptive timeout scale").size == 1 }).to_stderr_from_any_process
    end

    it "does not log the scale before warm-up" do
      cal = fake_calibrator(warmed: false)
      expect do
        scheduler(worker: killed_worker, calibrators: { parallel: cal, serial: cal }).run([item])
      end.not_to output(/adaptive timeout scale/).to_stderr_from_any_process
    end
  end

  it "runs serial-lane items one at a time, after the parallel lane" do
    # Workers run in forked child processes, so an in-memory Queue can't
    # observe cross-process ordering (fork gives each child its own copy —
    # pushes never reach the parent). Use a flock-guarded append log instead.
    Tempfile.create("order") do |file|
      log_path = file.path
      append = ->(line) { File.open(log_path, "a") { |f| f.flock(File::LOCK_EX); f.puts(line) } }
      worker = lambda do |_m, _e, writer|
        append.call("start")
        sleep 0.1
        append.call("finish")
        writer.puts(JSON.generate("status" => "killed", "details" => nil))
      end
      results = scheduler(worker: worker, jobs: 2, on_result: ->(_) { GC.start })
        .run([item(lane: :serial), item(lane: :serial)])
      expect(results.map(&:status)).to eq(%i[killed killed])
      events = File.readlines(log_path).map { |l| l.chomp.to_sym }
      expect(events).to eq(%i[start finish start finish]) # never two concurrent starts
    end
  end

  # A killer that reaches the next sibling (same Subject) saves it the slow
  # groups: the scheduler runs the killer's top-level group first. The plan
  # itself is never mutated.
  describe "covering group priority" do
    let(:a1) { "./spec/a_spec.rb[1:1]" }
    let(:b1) { "./spec/b_spec.rb[1:1]" }
    let(:c1) { "./spec/c_spec.rb[1:1]" }
    let(:ids) { [a1, b1, c1] }

    def work(mutation, ids, timeout: 5.0)
      ActiveMutator::WorkItem.new(mutation: mutation, example_ids: ids, timeout: timeout, lane: :parallel)
    end

    # Each mutant (picked by line) answers with a scripted payload; the order
    # the worker was handed travels back in `details`.
    def scripted(plan)
      lambda do |m, example_ids, writer|
        status, killer = plan.fetch(m.line)
        sleep 5 if status == "hang"
        writer.puts("not json{") if status == "garbage"
        payload = { "status" => status, "details" => example_ids.join(",") }
        payload["killer"] = killer unless killer.nil?
        writer.puts(JSON.generate(payload)) unless status == "garbage"
      end
    end

    def orders(results) = results.map { |r| r.details&.split(",") }

    def run_jobs1(plan, items, **) = described_class.new(jobs: 1, worker: scripted(plan), **).run(items)

    let(:foo) { mutation_in("/app/foo.rb", line: 1) }
    let(:foo2) { mutation_in("/app/foo.rb", line: 2) }
    let(:foo3) { mutation_in("/app/foo.rb", line: 3) }

    it "runs the killer's group first for the next sibling of the same subject" do
      results = run_jobs1({ 1 => ["killed", b1], 2 => ["killed", nil] }, [work(foo, ids), work(foo2, ids)])
      expect(orders(results)).to eq([ids, [b1, a1, c1]])
    end

    it "promotes the whole group, keeping the rest in plan order" do
      grouped = %w[./spec/a_spec.rb[1:1] ./spec/a_spec.rb[2:1] ./spec/b_spec.rb[1:1] ./spec/b_spec.rb[1:2]]
      results = run_jobs1({ 1 => ["killed", "./spec/b_spec.rb[1:2]"], 2 => ["killed", nil] },
                          [work(foo, grouped), work(foo2, grouped)])
      expect(orders(results).last).to eq(%w[./spec/b_spec.rb[1:1] ./spec/b_spec.rb[1:2] ./spec/a_spec.rb[1:1] ./spec/a_spec.rb[2:1]])
    end

    it "does not reorder a plan with a malformed id while no killer is known" do
      messy = [a1, "garbage", b1]
      results = run_jobs1({ 1 => ["killed", nil] }, [work(foo, messy)])
      expect(orders(results)).to eq([messy])
    end

    it "keeps a malformed id after the promoted group" do
      messy = [a1, "garbage", b1]
      results = run_jobs1({ 1 => ["killed", b1], 2 => ["killed", nil] }, [work(foo, ids), work(foo2, messy)])
      expect(orders(results).last).to eq([b1, a1, "garbage"])
    end

    it "matches the killer's top-level group, not the exact example" do
      # The sibling selected only b[1:1]; the killer was b[1:5] of another run.
      results = run_jobs1({ 1 => ["killed", "./spec/b_spec.rb[1:5]"], 2 => ["killed", nil] },
                          [work(foo, [a1, b1, "./spec/b_spec.rb[1:5]"]), work(foo2, [a1, c1, b1])])
      expect(orders(results).last).to eq([b1, a1, c1])
    end

    it "does not mix two top-level groups of one file" do
      results = run_jobs1({ 1 => ["killed", "./spec/a_spec.rb[2:1]"], 2 => ["killed", nil] },
                          [work(foo, ["./spec/a_spec.rb[1:1]", "./spec/a_spec.rb[2:1]"]),
                           work(foo2, ["./spec/a_spec.rb[1:1]", "./spec/a_spec.rb[2:1]", "./spec/a_spec.rb[2:2]"])])
      expect(orders(results).last).to eq(%w[./spec/a_spec.rb[2:1] ./spec/a_spec.rb[2:2] ./spec/a_spec.rb[1:1]])
    end

    it "accepts a killer spelled with an absolute path" do
      killer = "#{File.expand_path("spec/b_spec.rb")}[1:1]"
      results = run_jobs1({ 1 => ["killed", killer], 2 => ["killed", nil] }, [work(foo, ids), work(foo2, ids)])
      expect(orders(results).last).to eq([b1, a1, c1])
    end

    it "leaves the plan's own item untouched" do
      first = work(foo, ids)
      second = work(foo2, ids)
      run_jobs1({ 1 => ["killed", b1], 2 => ["killed", nil] }, [first, second])
      expect(second.example_ids).to eq(ids)
    end

    it "does not touch the statuses" do
      results = run_jobs1({ 1 => ["killed", b1], 2 => ["killed", nil] }, [work(foo, ids), work(foo2, ids)])
      expect(results.map(&:status)).to eq(%i[killed killed])
    end

    it "runs the first of an audit worker's killers first" do
      worker = lambda do |m, example_ids, writer|
        payload = { "status" => "killed", "details" => example_ids.join(",") }
        payload["killers"] = [c1, b1] if m.line == 1
        writer.puts(JSON.generate(payload))
      end
      results = described_class.new(jobs: 1, worker: worker).run([work(foo, ids), work(foo2, ids)])
      expect(orders(results).last).to eq([c1, a1, b1])
    end

    it "remembers the latest valid killer" do
      results = run_jobs1({ 1 => ["killed", b1], 2 => ["killed", c1], 3 => ["killed", nil] },
                          [work(foo, ids), work(foo2, ids), work(foo3, ids)])
      expect(orders(results)).to eq([ids, [b1, a1, c1], [c1, a1, b1]])
    end

    it "keeps each subject's killer apart, including the same name in another file" do
      other_file = mutation_in("/app/other.rb", line: 2)
      other_name = mutation_in("/app/foo.rb", name: "Foo#baz", line: 3)
      results = run_jobs1({ 1 => ["killed", b1], 2 => ["killed", nil], 3 => ["killed", nil] },
                          [work(foo, ids), work(other_file, ids), work(other_name, ids)])
      expect(orders(results)).to eq([ids, ids, ids])
    end

    it "keeps the killer through inconclusive outcomes of later siblings" do
      plan = { 1 => ["killed", b1], 2 => ["survived", nil], 3 => ["error", nil], 4 => ["killed", nil],
               5 => ["hang", nil], 6 => ["garbage", nil], 7 => ["killed", nil] }
      items = (1..7).map { |line| work(mutation_in("/app/foo.rb", line: line), ids, timeout: line == 5 ? 0.4 : 5.0) }
      results = run_jobs1(plan, items)
      expect(results.map(&:status)).to eq(%i[killed survived error killed timeout error killed])
      expect(orders(results).values_at(1, 2, 3, 6)).to all(eq([b1, a1, c1]))
    end

    {
      "a foreign example" => "./spec/zzz_spec.rb[1:1]",
      "a malformed id" => "garbage",
      "an id with no example part" => "./spec/b_spec.rb",
      "an empty string" => "",
      "a non-string" => 7,
      "a hash" => { "id" => "x" }
    }.each do |label, killer|
      it "ignores #{label} as a killer" do
        results = run_jobs1({ 1 => ["killed", killer], 2 => ["killed", nil] }, [work(foo, ids), work(foo2, ids)])
        expect(orders(results).last).to eq(ids)
      end
    end

    it "ignores a killer on a result that is not a kill" do
      %w[survived error skipped].each do |status|
        results = run_jobs1({ 1 => [status, b1], 2 => ["killed", nil] }, [work(foo, ids), work(foo2, ids)])
        expect(orders(results).last).to eq(ids), status
      end
    end

    it "does not learn from a payload whose stats line is unusable" do
      worker = lambda do |m, example_ids, writer|
        if m.line == 1
          writer.puts(JSON.generate("status" => "killed", "details" => nil, "killer" => b1))
          writer.puts("")
          writer.puts("not json{") # the scheduler's own stats line follows, but this one is read as stats
        else
          writer.puts(JSON.generate("status" => "killed", "details" => example_ids.join(",")))
        end
      end
      results = described_class.new(jobs: 1, worker: worker).run([work(foo, ids), work(foo2, ids)])
      expect(results.first.status).to eq(:error)
      expect(orders(results).last).to eq(ids)
    end

    it "does not change siblings already running when a kill lands" do
      results = described_class.new(jobs: 2, worker: scripted({ 1 => ["killed", b1], 2 => ["killed", nil] }))
                               .run([work(foo, ids), work(foo2, ids)])
      expect(orders(results)).to match_array([ids, ids])
    end

    it "prioritizes a sibling's group within a run when persistence is enabled" do
      Dir.mktmpdir do |root|
        memory = ActiveMutator::KillerMemory.new(root)
        worker = scripted({ 1 => ["killed", b1], 2 => ["killed", nil] })
        sibling = b1.sub("1:1", "1:2")
        results = described_class.new(jobs: 1, worker: worker, killer_memory: memory)
                                 .run([work(foo, ids), work(foo2, [a1, sibling])])
        expect(orders(results).last).to eq([sibling, a1])
      end
    end

    it "merges disjoint kills from overlapping runs" do
      Dir.mktmpdir do |root|
        first = ActiveMutator::KillerMemory.new(root)
        second = ActiveMutator::KillerMemory.new(root)
        other = mutation_in("/app/other.rb", line: 1)
        worker = scripted({ 1 => ["killed", b1] })
        described_class.new(jobs: 1, worker: worker, killer_memory: first).run([work(foo, ids)])
        described_class.new(jobs: 1, worker: worker, killer_memory: second).run([work(other, ids)])
        first.save
        second.save
        restored = ActiveMutator::KillerMemory.new(root)
        expect(restored.group_for(work(foo, ids))).to eq(ActiveMutator::ExampleId.group_key(b1))
        expect(restored.group_for(work(other, ids))).to eq(ActiveMutator::ExampleId.group_key(b1))
      end
    end

    it "seeds the first mutant from a verified killer saved by a previous scheduler" do
      Dir.mktmpdir do |root|
        memory = ActiveMutator::KillerMemory.new(root)
        worker = scripted({ 1 => ["killed", b1], 2 => ["killed", nil] })
        described_class.new(jobs: 1, worker: worker, killer_memory: memory).run([work(foo, ids)])
        memory.save

        reloaded = ActiveMutator::KillerMemory.new(root)
        scheduler = described_class.new(jobs: 1, worker: worker, killer_memory: reloaded)
        expect(orders(scheduler.run([work(foo2, ids)]))).to eq([[b1, a1, c1]])

        changed_ids = [a1, c1, b1.sub("1:1", "1:2")]
        expect(orders(scheduler.run([work(foo2, changed_ids)]))).to eq([changed_ids])
      end
    end

    it "forgets everything between runs of one scheduler" do
      sched = described_class.new(jobs: 1, worker: scripted({ 1 => ["killed", b1], 2 => ["killed", nil] }))
      sched.run([work(foo, ids)])
      expect(orders(sched.run([work(foo2, ids)]))).to eq([ids])
    end

    it "hands a custom worker exactly the mutation, ids, and writer" do
      arities = []
      worker = lambda do |*args|
        args.last.puts(JSON.generate("status" => "killed", "details" => args.size.to_s))
      end
      arities = described_class.new(jobs: 1, worker: worker).run([work(foo, ids)]).map(&:details)
      expect(arities).to eq(["3"])
    end
  end

  describe "the killers a result keeps" do
    let(:a1) { "./spec/a_spec.rb[1:1]" }
    let(:b1) { "./spec/b_spec.rb[1:1]" }
    let(:ids) { [a1, b1] }
    let(:foo) { mutation_in("/app/foo.rb", line: 1) }

    def killed_by(payload)
      worker = ->(_m, _ids, writer) { writer.puts(JSON.generate({ "details" => nil }.merge(payload))) }
      item = ActiveMutator::WorkItem.new(mutation: foo, example_ids: ids, timeout: 5.0, lane: :parallel)
      described_class.new(jobs: 1, worker: worker).run([item]).first.killed_by
    end

    it "keeps the killer the worker named, spelled as it was reported" do
      killer = "#{File.expand_path("spec/b_spec.rb")}[1:1]"
      expect(killed_by("status" => "killed", "killer" => killer)).to eq([killer])
    end

    it "keeps none when the worker named none" do
      expect(killed_by("status" => "killed")).to eq([])
    end

    it "keeps every killer an audit worker named, in its order, over the single killer" do
      payload = { "status" => "killed", "killer" => a1, "killers" => [b1, a1] }
      expect(killed_by(payload)).to eq([b1, a1])
    end

    it "keeps none when an audit worker named an empty list" do
      expect(killed_by("status" => "killed", "killer" => a1, "killers" => [])).to eq([])
    end

    it "drops killers that are not among the examples it was given" do
      payload = { "status" => "killed", "killers" => ["./spec/zzz_spec.rb[1:1]", b1, "garbage", 7] }
      expect(killed_by(payload)).to eq([b1])
    end

    it "keeps none for a result that is not a kill" do
      %w[survived error skipped].each do |status|
        expect(killed_by("status" => status, "killer" => b1, "killers" => [b1])).to eq([]), status
      end
    end

    it "keeps none for a report without a status" do
      expect(killed_by("killer" => b1)).to eq([])
    end
  end

  describe "the passes a result keeps" do
    let(:a1) { "./spec/a_spec.rb[1:1]" }
    let(:b1) { "./spec/b_spec.rb[1:1]" }
    let(:foo) { mutation_in("/app/foo.rb", line: 1) }

    def passed(payload)
      worker = ->(_m, _ids, writer) { writer.puts(JSON.generate({ "status" => "survived", "details" => nil }.merge(payload))) }
      item = ActiveMutator::WorkItem.new(mutation: foo, example_ids: [a1, b1], timeout: 5.0, lane: :parallel)
      described_class.new(jobs: 1, worker: worker).run([item]).first.passed
    end

    it "keeps the passes an audit worker reported, with their locations" do
      expect(passed("passed" => { a1 => "./spec/a_spec.rb:3" })).to eq(a1 => "./spec/a_spec.rb:3")
    end

    it "keeps none when the worker reported none" do
      expect(passed({})).to eq({})
    end

    it "keeps none when the report is not a map" do
      expect(passed("passed" => [a1])).to eq({})
    end

    it "drops passes without a location string or outside the examples it was given" do
      payload = { "passed" => { a1 => 3, b1 => "./spec/b_spec.rb:1", "./spec/zzz_spec.rb[1:1]" => "./spec/zzz_spec.rb:1",
                                "garbage" => "x:1" } }
      expect(passed(payload)).to eq(b1 => "./spec/b_spec.rb:1")
    end

    it "keeps passes on a kill too" do
      expect(passed("status" => "killed", "killers" => [a1], "passed" => { b1 => "b:1" })).to eq(b1 => "b:1")
    end
  end

  describe "the ignored examples a result keeps" do
    let(:a1) { "./spec/a_spec.rb[1:1]" }
    let(:b1) { "./spec/b_spec.rb[1:1]" }

    def ignored(payload)
      worker = ->(_m, _ids, writer) { writer.puts(JSON.generate({ "status" => "survived", "details" => nil }.merge(payload))) }
      item = ActiveMutator::WorkItem.new(mutation: mutation_in("/app/foo.rb", line: 1), example_ids: [a1, b1],
                                         timeout: 5.0, lane: :parallel)
      described_class.new(jobs: 1, worker: worker).run([item]).first.ignored
    end

    it "keeps the tagged examples an audit worker reported, if it was given them" do
      expect(ignored("ignored" => [b1, "./spec/zzz_spec.rb[1:1]", 3, "garbage"])).to eq([b1])
    end

    it "keeps none when the worker reported none, or not a list" do
      expect(ignored({})).to eq([])
      expect(ignored("ignored" => { a1 => "a:1" })).to eq([])
    end
  end
end
