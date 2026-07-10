require "json"

module ActiveMutator
  # Fork pool: one fork per WorkItem, capped at `jobs` concurrent forks.
  # Parent enforces per-item deadlines with SIGKILL (worker-side timeouts
  # cannot interrupt all infinite loops).
  class Scheduler
    def initialize(jobs:, worker: Worker.method(:run), on_result: nil)
      @jobs = jobs
      @worker = worker
      @on_result = on_result
    end

    def run(items)
      previous_traps = nil
      running = {}
      previous_traps = install_signal_handlers(running)
      results = []
      # Browser-covered mutants each boot Chrome + an app server; running them
      # concurrently melts CPUs and manufactures false timeouts. Parallel lane
      # first at full width, then the serial lane one at a time.
      results.concat(run_pool(items.select { |i| i.lane == :parallel }, @jobs, running))
      results.concat(run_pool(items.select { |i| i.lane == :serial }, 1, running))
      results
    ensure
      restore_traps(previous_traps) if previous_traps
    end

    private

    def run_pool(items, width, running)
      queue = items.dup
      results = []
      until queue.empty? && running.empty?
        spawn(queue.shift, running) while running.size < width && !queue.empty?
        reap(running, results)
        sleep 0.02 unless running.empty?
      end
      results
    end

    def spawn(item, running)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        Process.setpgid(0, 0)          # own process group: deadline kill reaps grandchildren too
        $stdout.reopen(File::NULL)     # app code that prints must not corrupt parent's report
        $stderr.reopen(File::NULL)     # ditto for warnings (RSpec/app noise interleaves with reports)
        @worker.call(item.mutation, item.example_ids, writer)
        writer.close
        Process.exit!(0)
      end
      writer.close
      running[pid] = { reader: reader, item: item, deadline: now + item.timeout }
    end

    def reap(running, results)
      running.to_a.each do |pid, entry|
        done, _status = Process.waitpid2(pid, Process::WNOHANG)
        if done
          running.delete(pid)
          results << finish(entry)
        elsif now > entry[:deadline]
          kill(pid)
          running.delete(pid)
          entry[:reader].close
          results << report(Result.new(mutation: entry[:item].mutation, status: :timeout, details: nil))
        end
      end
    end

    def finish(entry)
      payload = entry[:reader].read.to_s
      entry[:reader].close
      data = payload.empty? ? nil : JSON.parse(payload)
      status = data ? data.fetch("status").to_sym : :error
      details = data ? data["details"] : "worker exited without reporting"
      report(Result.new(mutation: entry[:item].mutation, status: status, details: details))
    end

    def report(result)
      @on_result&.call(result)
      result
    end

    def kill(pid)
      Process.kill("KILL", -pid) # negative pid = whole process group
    rescue Errno::ESRCH, Errno::EPERM
      # Group not established yet (setpgid race) or already gone — direct kill.
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    ensure
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end

    # Returns {sig => previous_handler} so #run can restore on exit —
    # otherwise our traps permanently replace the host's (e.g. RSpec's Ctrl-C).
    def install_signal_handlers(running)
      %w[INT TERM].to_h do |sig|
        previous = trap(sig) do
          running.each_key do |pid|
            Process.kill("KILL", -pid)
          rescue StandardError
            nil
          end
          exit(130)
        end
        [sig, previous]
      end
    end

    def restore_traps(previous)
      previous.each { |sig, handler| trap(sig, handler || "DEFAULT") }
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
