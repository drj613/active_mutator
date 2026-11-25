require "json"
require "tempfile"

module ActiveMutator
  # Fork pool: one fork per WorkItem, capped at `jobs` concurrent forks.
  # The parent enforces per-item deadlines (worker-side timeouts cannot
  # interrupt all infinite loops): SIGTERM to the worker's process group,
  # then SIGKILL if it is still there after a short grace.
  class Scheduler
    OrphanedError = Class.new(Error)

    # Long enough for a test server's at_exit shutdown, short enough that a
    # stuck worker doesn't hold its slot for long. A worker that has
    # reported gets this long to exit, then the same again after TERM.
    TERM_GRACE = 3.0

    # A detached run can start with pid 1 as its parent, so compare against
    # the parent seen at start rather than against 1.
    def self.parent_changed
      start = Process.ppid
      -> { Process.ppid != start }
    end

    # first_seq: phase-2 escalation runs on its own scheduler; starting its
    # sequence after phase 1's keeps mutant numbers unique across the run.
    def initialize(jobs:, worker: Worker.method(:run), on_result: nil,
                   calibrators: nil, orphaned: Scheduler.parent_changed,
                   events: Events.new, first_seq: 1, abort: AbortFlag.new, term_grace: TERM_GRACE, killer_memory: nil)
      @killer_memory = killer_memory
      @abort = abort
      @term_grace = term_grace
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
      @killers = {} # Subject => [file, top-level group] of its latest killer
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
      # A worker that reported, or ran past its deadline, already has its
      # verdict; it isn't in flight.
      settled, live = running.partition { |_, entry| entry[:reported_at] || entry[:stopping] }
      settled.each { |pid, entry| results << complete(pid, entry, settled_result(entry)) }
      in_flight = live.map do |pid, entry|
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
    # init/launchd; when the parent changes, stop everything and bail.
    def abort_if_orphaned!(running)
      return unless @orphaned.call

      raise OrphanedError, "parent process died; aborting mutation run"
    end

    def cleanup(running, wait: true)
      running.each_key { |pid| signal_group(pid) }
      running.each do |pid, entry|
        entry[:reader].close
        entry[:stderr_file].close!
        Process.waitpid(pid) if wait
      rescue Errno::ECHILD
        nil
      end
      running.clear
    end

    STDERR_TAIL_LINES = 20

    def spawn(item, running)
      item = prioritized(item)
      calibrator = calibrator_for(item)
      budget = calibrator ? calibrator.budget_for(item) : item.timeout
      log_scale(calibrator, item.lane)
      reader, writer = IO.pipe
      stderr_file = Tempfile.new("active_mutator-worker")
      pid = fork do
        reader.close
        Process.setpgid(0, 0)          # own process group: deadline kill reaps grandchildren too
        # Forks inherit the Runner's TERM trap, which only trips the abort
        # flag. Ruby's own handler raises, so the worker's at_exit hooks run.
        trap("TERM", "DEFAULT")
        $stdout.reopen(File::NULL)     # app code that prints must not corrupt parent's report
        $stderr.reopen(stderr_file.path, "w") # kept for the crash report, never shown otherwise
        # After fork(), libpq's GSS encryption negotiation touches Apple
        # frameworks and segfaults the child on macOS; disabling it is
        # harmless everywhere else.
        ENV["PGGSSENCMODE"] ||= "disable"
        # at_exit hooks run newest first: the worker's own (a test server's
        # shutdown) run, then this one stops before the parent's inherited
        # ones. It exits 0 for the block's normal exit below.
        at_exit { Process.exit!(0) }
        begin
          @worker.call(item.mutation, item.example_ids, writer)
        rescue Exception => e # rubocop:disable Lint/RescueException
          # The hook above exits before Ruby prints an uncaught error, so
          # print it here, message last, where the stderr tail keeps it.
          $stderr.puts(e.full_message(highlight: false, order: :bottom)) unless e.is_a?(SystemExit)
          $stderr.flush
          raise
        end
        # A second line, after the worker's own report: the worker can exit
        # between two memory samples, so it reports its peak itself.
        writer.puts("", JSON.generate("peak_rss_kb" => MemoryProbe.peak_rss_kb))
        writer.close
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
        reader&.close
        writer&.close
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
        if chunk.is_a?(String)
          entry[:payload] << chunk
          # The report is one line of JSON, and the worker's last word on
          # the verdict: once its newline is in, the verdict is final.
          entry[:reported_at] ||= now if chunk.include?("\n")
        end
        entry[:eof] = true if chunk.nil?
        entry[:exited] ||= Process.waitpid(pid, Process::WNOHANG)
        if entry[:stopping]
          next unless entry[:exited] || now > entry[:stopping][:kill_at]

          kill(pid) # whatever is left of the group, a descendant holding the pipe included
          results << complete(pid, entry, settled_result(entry))
          running.delete(pid)
        elsif entry[:exited] && entry[:eof]
          results << complete(pid, entry, reported_result(entry, now - entry[:started]))
          running.delete(pid)
        elsif entry[:reported_at] ? now > entry[:reported_at] + @term_grace : now > entry[:deadline]
          # TERM first, so the worker's own cleanup (a test server's
          # shutdown) runs. The verdict is already set: the report, or a
          # timeout if none came. Its at_exit hooks (a coverage report, say)
          # or a descendant holding the pipe can't change it.
          signal_group(pid, "TERM")
          entry[:stopping] = { seconds: now - entry[:started], kill_at: now + @term_grace }
        end
      end
    end

    # A stopped worker's verdict: its report, timed to when it came, or a
    # timeout.
    def settled_result(entry)
      return reported_result(entry, entry[:reported_at] - entry[:started]) if entry[:reported_at]

      entry[:reader].close
      entry[:stderr_file].close!
      timeout_result(entry)
    end

    def reported_result(entry, seconds)
      result = finish(entry, seconds)
      calibrator_for(entry[:item])&.record(result.seconds, entry[:budget]) if result.status == :killed
      result
    end

    def timeout_result(entry)
      seconds = entry[:stopping][:seconds]
      details = format("timed out after %.1fs (budget %.1fs)", seconds, entry[:budget])
      Result.new(mutation: entry[:item].mutation, status: :timeout, details: details, seconds: seconds)
    end

    # A sibling mutant of the same subject (the plan is built per mutant, so
    # the covering set is the same or close) most likely dies to the same
    # spec: run the group that killed the last one first. The set is unchanged.
    def prioritized(item)
      key = @killers[item.mutation.subject] || @killer_memory&.group_for(item)
      return item unless key

      first, rest = item.example_ids.partition { |id| ExampleId.group_key(id) == key }
      item.with(example_ids: first + rest)
    end

    # Only a kill that names one of the examples it was given counts. Anything
    # else (missing, malformed, foreign, or on another status) is dropped, and
    # leaves the last killer alone. An audit worker names every killer.
    def verified_killers(item, status, data)
      return [] unless status == :killed

      selected = selected(item)
      Array(data["killers"] || data["killer"]).select { |id| selected.include?(ExampleId.normalize(id)) }
    end

    # An audit worker's passes, held to the same rule: only selected examples.
    def verified_passes(item, data)
      passes = data["passed"]
      return {} unless passes.is_a?(Hash)

      selected = selected(item)
      passes.select { |id, location| location.is_a?(String) && selected.include?(ExampleId.normalize(id)) }
    end

    # The tagged examples an audit worker ran, by the same rule.
    def verified_ignored(item, data)
      ignored = data["ignored"]
      return [] unless ignored.is_a?(Array)

      selected = selected(item)
      ignored.select { |id| selected.include?(ExampleId.normalize(id)) } # normalize: nil for a non-String
    end

    def selected(item) = item.example_ids.filter_map { |id| ExampleId.normalize(id) }

    def learn_killer(item, killer)
      return unless killer

      @killers[item.mutation.subject] = ExampleId.group_key(killer)
      @killer_memory&.remember(item, killer)
    end

    def finish(entry, seconds)
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
      # Learned only once the whole payload (report and stats) has parsed.
      killed_by = verified_killers(entry[:item], status, data) # [] unless reported as a kill
      learn_killer(entry[:item], killed_by.first)
      Result.new(mutation: entry[:item].mutation, status: status, details: details,
                 seconds: seconds, peak_rss_kb: peak, killed_by: killed_by,
                 passed: reported ? verified_passes(entry[:item], data) : {},
                 ignored: reported ? verified_ignored(entry[:item], data) : [])
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

    def signal_group(pid, signal = "KILL")
      Process.kill(signal, -pid) # negative pid = whole process group
    rescue Errno::ESRCH, Errno::EPERM
      # Group not established yet (setpgid race) or already gone: direct kill.
      begin
        Process.kill(signal, pid)
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
