require "json"
require "tempfile"

module ActiveMutator
  # Fork pool: one fork per WorkItem, capped at `jobs` concurrent forks.
  # Parent enforces per-item deadlines with SIGKILL (worker-side timeouts
  # cannot interrupt all infinite loops).
  class Scheduler
    OrphanedError = Class.new(Error)

    # first_seq: phase-2 escalation runs on its own scheduler; starting its
    # sequence after phase 1's keeps mutant numbers unique across the run.
    def initialize(jobs:, worker: Worker.method(:run), on_result: nil,
                   calibrators: nil, orphaned: -> { Process.ppid == 1 },
                   events: Events.new, first_seq: 1, abort: AbortFlag.new)
      @abort = abort
      @jobs = jobs
      @worker = worker
      @on_result = on_result
      @calibrators = calibrators
      @orphaned = orphaned
      @events = events
      @next_seq = first_seq
      @last_logged_scale = {} # lane => last scale logged for that lane
    end

    # Signals are the Runner's: its AbortFlag trips, and the poll loop here
    # kills every worker and raises Aborted with what finished.
    def run(items)
      running = {}
      results = []
      @abort.deferred do
        # Browser-covered mutants each boot Chrome + an app server; running
        # them concurrently melts CPUs and manufactures false timeouts.
        # Parallel lane first at full width, then the serial lane one at a time.
        run_pool(items.select { |i| i.lane == :parallel }, @jobs, running, results)
        run_pool(items.select { |i| i.lane == :serial }, 1, running, results)
      end
      results
    ensure
      cleanup(running)
    end

    private

    def run_pool(items, width, running, results)
      queue = items.dup
      until queue.empty? && running.empty?
        abort_if_orphaned!(running)
        abort!(running, results) if @abort.tripped?
        # A trip mid-fill stops the forking; the next pass kills what started.
        spawn(queue.shift, running) while running.size < width && !queue.empty? && !@abort.tripped?
        reap(running, results)
        sleep 0.02 unless running.empty?
      end
    end

    # CI allows only seconds between SIGTERM and SIGKILL, so kill every
    # worker group and move on without waiting for any of them.
    def abort!(running, results)
      in_flight = running.map do |pid, entry|
        m = entry[:item].mutation
        { seq: entry[:seq], pid: pid, subject: m.subject.name, file: m.subject.file, line: m.line,
          description: m.description }
      end
      cleanup(running, wait: false)
      raise Aborted.new(@abort.reason, results: results, in_flight: in_flight)
    end

    # SIGKILL on the parent (or a closed terminal, or CI teardown) cannot be
    # trapped, so a killed run would otherwise keep forking through the whole
    # queue with nobody supervising it. Orphaned processes get reparented to
    # init/launchd (ppid 1); when that happens, stop everything and bail.
    def abort_if_orphaned!(running)
      return unless @orphaned.call

      raise OrphanedError, "parent process died; aborting mutation run"
    end

    def cleanup(running, wait: true)
      running.each_key { |pid| signal_group(pid) }
      running.each do |pid, entry|
        entry[:reader].close unless entry[:reader].closed?
        entry[:stderr_file].close!
        Process.waitpid(pid) if wait
      rescue Errno::ECHILD
        nil
      end
      running.clear
    end

    STDERR_TAIL_LINES = 20

    def spawn(item, running)
      calibrator = calibrator_for(item)
      budget = calibrator ? calibrator.budget_for(item) : item.timeout
      log_scale(calibrator, item.lane)
      reader, writer = IO.pipe
      stderr_file = Tempfile.new("active_mutator-worker")
      pid = fork do
        reader.close
        Process.setpgid(0, 0)          # own process group: deadline kill reaps grandchildren too
        $stdout.reopen(File::NULL)     # app code that prints must not corrupt parent's report
        $stderr.reopen(stderr_file.path, "w") # kept for the crash report, never shown otherwise
        # After fork(), libpq's GSS encryption negotiation touches Apple
        # frameworks and segfaults the child on macOS; disabling it is
        # harmless everywhere else.
        ENV["PGGSSENCMODE"] ||= "disable"
        @worker.call(item.mutation, item.example_ids, writer)
        # A second line, after the worker's own report: the worker can exit
        # between two memory samples, so it reports its peak itself.
        writer.puts("", JSON.generate("peak_rss_kb" => MemoryProbe.peak_rss_kb))
        writer.close
        Process.exit!(0)
      end
      writer.close
      started = now
      seq = @next_seq
      @next_seq += 1
      running[pid] = { reader: reader, item: item, started: started, stderr_file: stderr_file,
                       budget: budget, deadline: started + budget, seq: seq, payload: +"" }
      emit_start(item, pid, seq, budget) if @events.listening?
    ensure
      unless pid
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        stderr_file&.close!
      end
    end

    def emit_start(item, pid, seq, budget)
      m = item.mutation
      @events.emit(:mutant_start, seq: seq, pid: pid, lane: item.lane, budget: budget,
                                  examples: item.example_ids.size, subject: m.subject.name,
                                  file: m.subject.file, line: m.line, description: m.description)
    end

    def reap(running, results)
      running.to_a.each do |pid, entry|
        # Read while the worker runs so a full pipe cannot prevent its exit.
        # A descendant may retain the writer after that exit; keep the group
        # tracked until EOF so aborts and the deadline still apply to it.
        chunk = entry[:reader].read_nonblock(65_536, exception: false)
        entry[:payload] << chunk if chunk.is_a?(String)
        entry[:eof] = true if chunk.nil?
        entry[:exited] ||= Process.waitpid(pid, Process::WNOHANG)
        if entry[:exited] && entry[:eof]
          result = finish(entry)
          calibrator_for(entry[:item])&.record(result.seconds, entry[:budget]) if result.status == :killed
          results << complete(pid, entry, result)
          running.delete(pid)
        elsif now > entry[:deadline]
          kill(pid)
          entry[:reader].close
          entry[:stderr_file].close!
          seconds = now - entry[:started]
          details = format("timed out after %.1fs (budget %.1fs)", seconds, entry[:budget])
          results << complete(pid, entry, Result.new(mutation: entry[:item].mutation, status: :timeout,
                                                     details: details, seconds: seconds))
          running.delete(pid)
        end
      end
    end

    def finish(entry)
      seconds = now - entry[:started]
      report_line, stats_line = entry[:payload].lines.map(&:strip).reject(&:empty?)
      entry[:reader].close
      stderr_tail = stderr_tail(entry[:stderr_file])
      data = report_line && JSON.parse(report_line)
      # A self-mutation of Worker#emit can produce well-formed JSON without a
      # "status" key (or with a non-Hash root); treat any unusable payload as
      # a worker error instead of crashing the whole run.
      reported = data.is_a?(Hash) && data.key?("status")
      status = reported ? data["status"].to_sym : :error
      details = reported ? data["details"] : unreported_details(stderr_tail)
      peak = JSON.parse(stats_line)["peak_rss_kb"] if stats_line
    rescue JSON::ParserError
      Result.new(mutation: entry[:item].mutation, status: :error,
                 details: "worker emitted unparseable payload", seconds: seconds)
    else
      Result.new(mutation: entry[:item].mutation, status: status, details: details,
                 seconds: seconds, peak_rss_kb: peak)
    end

    def complete(pid, entry, result)
      @events.emit(:mutant_end, seq: entry[:seq], pid: pid, status: result.status,
                                seconds: result.seconds, peak_rss_kb: result.peak_rss_kb)
      report(result)
    end

    def report(result)
      @on_result&.call(result)
      result
    end

    # The child wrote through its own descriptor (reopened by path), so this
    # handle is still at offset 0: no rewind needed.
    def stderr_tail(file)
      file.read.to_s.lines.last(STDERR_TAIL_LINES).join.strip
    ensure
      file.close!
    end

    def unreported_details(stderr_tail)
      return "worker exited without reporting" if stderr_tail.empty?

      "worker exited without reporting; stderr tail:\n#{stderr_tail}"
    end

    def kill(pid)
      signal_group(pid)
    ensure
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end

    def signal_group(pid)
      Process.kill("KILL", -pid) # negative pid = whole process group
    rescue Errno::ESRCH, Errno::EPERM
      # Group not established yet (setpgid race) or already gone: direct kill.
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def calibrator_for(item)
      @calibrators && @calibrators[item.lane]
    end

    # Effective budgets are otherwise invisible (--debug-plan shows static
    # ones by design). One stderr line per scale CHANGE per lane, not per
    # spawn — the two lanes calibrate independently, so the lane is named.
    def log_scale(calibrator, lane)
      return unless calibrator&.warmed?

      scale = calibrator.scale.round(2)
      return if scale == @last_logged_scale[lane]

      @last_logged_scale[lane] = scale
      warn "active_mutator: adaptive timeout scale (#{lane}): #{scale}"
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
