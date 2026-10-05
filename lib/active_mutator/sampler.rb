module ActiveMutator
  # Samples the gem's own memory: the parent, every live worker, and the
  # baseline child. Either side alone tells half the story (0.6.0 died in
  # the parent, right after the child). It learns worker and child pids from
  # the event stream, samples at every phase boundary, and, once started,
  # every `interval` seconds on its own thread. That thread only reads files
  # and emits, so forks from the main thread stay safe: a fork copies only
  # the calling thread.
  class Sampler
    def initialize(events:, interval:, probe: MemoryProbe.new, parent_pid: Process.pid)
      @events = events
      @interval = interval
      @probe = probe
      @parent_pid = parent_pid
      @workers = {} # pid => seq
      @lock = Mutex.new
    end

    # Events listener: follows pids, and samples at each phase boundary.
    def call(event)
      fields = event.fields
      case event.type
      when :mutant_start then @lock.synchronize { @workers[fields[:pid]] = fields[:seq] }
      when :mutant_end then @lock.synchronize { @workers.delete(fields[:pid]) }
      when :phase_start, :phase_end
        follow_baseline(fields) if fields[:phase] == :baseline
        tick
      end
    end

    # One sample, emitted as a `memory` event. Returns the total in KB (Pss
    # where the platform has it, else RSS, which overcounts shared pages),
    # nil when nothing could be read. Public so specs call it directly.
    def tick
      workers, baseline_pid = @lock.synchronize { [@workers.dup, @baseline_pid] }
      readings = @probe.processes([@parent_pid, *workers.keys, baseline_pid].compact)
      live = workers.filter_map { |pid, seq| readings[pid]&.then { |r| { pid: pid, seq: seq, **sizes(r) } } }
      baseline = readings[baseline_pid]&.then { |r| { pid: baseline_pid, **sizes(r) } }
      total = readings.empty? ? nil : readings.each_value.sum { |r| r[:pss_kb] || r[:rss_kb] }
      @events.emit(:memory, parent: readings[@parent_pid]&.then { |r| sizes(r) }, workers: live,
                            baseline: baseline, total_pss_kb: total, system: @probe.system)
      total
    end

    def start
      @thread = Thread.new do
        loop do
          sleep @interval
          tick
        end
      end
      self
    end

    def stop
      @thread&.kill&.join
    end

    private

    # phase_start carries the child's pid; phase_end carries none, so it
    # clears it.
    def follow_baseline(fields)
      @lock.synchronize { @baseline_pid = fields[:pid] }
    end

    def sizes(reading) = reading.slice(:rss_kb, :pss_kb)
  end
end
