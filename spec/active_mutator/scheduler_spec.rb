require "json"
require "tempfile"
require "tmpdir"

RSpec.describe ActiveMutator::Scheduler do
  def item(timeout: 5.0, lane: :parallel)
    ActiveMutator::WorkItem.new(mutation: nil, example_ids: [], timeout: timeout, lane: lane)
  end

  def scheduler(worker:, jobs: 2, on_result: nil)
    described_class.new(jobs: jobs, worker: worker, on_result: on_result)
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

  it "terminates workers with exit! so child at_exit hooks never run" do
    Dir.mktmpdir do |dir|
      flag = File.join(dir, "flag")
      worker = lambda do |_m, _e, writer|
        at_exit { File.write(flag, "ran") }
        writer.puts(JSON.generate("status" => "killed", "details" => nil))
      end
      scheduler(worker: worker).run([item])
      expect(File.exist?(flag)).to be(false)
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

  it "kills running workers and exits with status 130 on SIGINT" do
    # Touch install_signal_handlers in THIS process too: the real assertion runs
    # in a fork, and forked coverage never reaches the baseline coverage map, so
    # without this the example is never selected to run against these mutants.
    scheduler(worker: ->(_m, _e, _w) {}).run([])
    Dir.mktmpdir do |dir|
      worker_pid_file = File.join(dir, "worker_pid")
      supervisor = fork do
        sched = described_class.new(jobs: 1, worker: lambda do |_m, _e, _w|
          File.write(worker_pid_file, Process.pid.to_s)
          sleep 30
        end)
        sched.run([item])
        Process.exit!(99) # unreachable: the INT trap must exit the process first
      end
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.05 until File.exist?(worker_pid_file) ||
                         Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        expect(File).to exist(worker_pid_file) # clean failure instead of ENOENT on slow CI
        worker_pid = File.read(worker_pid_file).to_i
        expect(worker_pid).to be > 0
        Process.kill("INT", supervisor)
        status = wait_with_deadline(supervisor, 5)
        expect(status&.exitstatus).to eq(130)
        expect_process_gone(worker_pid)
      ensure
        begin
          Process.kill("KILL", supervisor)
          Process.waitpid(supervisor)
        rescue StandardError
          nil
        end
        if File.exist?(worker_pid_file)
          [-File.read(worker_pid_file).to_i, File.read(worker_pid_file).to_i].each do |target|
            Process.kill("KILL", target)
          rescue StandardError
            nil
          end
        end
      end
    end
  end

  it "installs INT handling for the duration of the run and restores the previous handler" do
    sentinel = proc {}
    previous_int = trap("INT", sentinel)
    begin
      during = nil
      worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
      on_result = lambda do |_r|
        during = trap("INT", sentinel) # peek at the active handler...
        trap("INT", during)            # ...and put it straight back
      end
      scheduler(worker: worker, on_result: on_result).run([item])
      expect(during).not_to eq(sentinel) # scheduler's own handler was active mid-run
      expect(trap("INT", "DEFAULT")).to eq(sentinel) # original handler restored after
    ensure
      trap("INT", previous_int || "DEFAULT")
    end
  end

  it "restores DEFAULT for signals whose previous handler was nil" do
    trap("USR1", proc {})
    scheduler(worker: ->(_m, _e, _w) {}).send(:restore_traps, { "USR1" => nil })
    expect(trap("USR1", "DEFAULT")).to eq("DEFAULT")
  end

  it "aborts and kills workers when the parent is orphaned" do
    checks = 0
    orphaned = -> { (checks += 1) > 1 } # healthy on the first tick, orphaned after
    worker = ->(_m, _e, _w) { sleep 30 }
    sched = described_class.new(jobs: 2, worker: worker, orphaned: orphaned)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { sched.run([item, item, item]) }
      .to raise_error(ActiveMutator::Scheduler::OrphanedError, /parent process died/)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 5 # workers were killed, not waited out
  end

  it "leaves no live worker processes behind after an orphaned abort" do
    pid_file = Tempfile.new("pids").path
    worker = lambda do |_m, _e, _w|
      File.open(pid_file, "a") { |f| f.flock(File::LOCK_EX); f.puts(Process.pid) }
      sleep 30
    end
    orphaned = -> { File.read(pid_file).lines.size >= 2 } # both workers running
    sched = described_class.new(jobs: 2, worker: worker, orphaned: orphaned)
    expect { sched.run([item, item]) }
      .to raise_error(ActiveMutator::Scheduler::OrphanedError)
    pids = File.readlines(pid_file).map(&:to_i)
    expect(pids.size).to eq(2)
    pids.each { |pid| expect_process_gone(pid) }
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

  it "kills over-deadline workers and marks :timeout" do
    worker = ->(_m, _e, _w) { sleep 30 }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = scheduler(worker: worker).run([item(timeout: 0.2)])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(results.map(&:status)).to eq([:timeout])
    expect(elapsed).to be < 5
  end

  it "actually kills the timed-out worker process and closes its pipe" do
    GC.disable
    pid_file = Tempfile.new("pid").path
    baseline = Dir.children("/dev/fd").size
    worker = lambda do |_m, _e, _w|
      File.write(pid_file, Process.pid.to_s)
      sleep 30
    end
    results = scheduler(worker: worker).run([item(timeout: 0.3)])
    expect(results.map(&:status)).to eq([:timeout])
    pid = File.read(pid_file).to_i
    expect(pid).to be > 0
    expect_process_gone(pid)
    expect(Dir.children("/dev/fd").size).to eq(baseline)
  ensure
    GC.enable
    begin
      Process.kill("KILL", File.read(pid_file).to_i) # cleanup if the mutant leaked it
    rescue StandardError
      nil
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

  it "runs serial-lane items one at a time, after the parallel lane" do
    # Workers run in forked child processes, so an in-memory Queue can't
    # observe cross-process ordering (fork gives each child its own copy —
    # pushes never reach the parent). Use a flock-guarded append log instead.
    log_path = Tempfile.new("order").path
    append = ->(line) { File.open(log_path, "a") { |f| f.flock(File::LOCK_EX); f.puts(line) } }
    worker = lambda do |_m, _e, writer|
      append.call("start")
      sleep 0.1
      append.call("finish")
      writer.puts(JSON.generate("status" => "killed", "details" => nil))
    end
    scheduler(worker: worker, jobs: 2).run([item(lane: :serial), item(lane: :serial)])
    events = File.readlines(log_path).map { |l| l.chomp.to_sym }
    expect(events).to eq(%i[start finish start finish]) # never two concurrent starts
  end
end
