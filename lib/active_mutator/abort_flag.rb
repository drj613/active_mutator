module ActiveMutator
  # A run stopped early by SIGINT, SIGTERM, or the memory ceiling. Carries
  # what finished (`results`) and what was still running (`in_flight`).
  class Aborted < StandardError
    attr_reader :reason, :results, :in_flight

    def initialize(reason, results: [], in_flight: [])
      super("run aborted: #{reason}")
      @reason = reason
      @results = results
      @in_flight = in_flight
    end

    # The same abort, with the finished results a caller up the stack knows.
    def with_results(results) = self.class.new(reason, results: results, in_flight: in_flight)
  end

  # Where a signal or a memory breach lands. `trip!` is safe in a trap
  # handler: no I/O and no locks (a Mutex in a trap raises ThreadError).
  #
  # Outside a `deferred` block, a trip raises Aborted on the main thread at
  # once: boot and planning own no child processes, so there is nothing to
  # clean up. Inside one (the baseline child's wait, the fork pool) it only
  # records the reason; the owner's poll loop kills its children and then
  # raises with what it knows. The first reason wins, and later trips are
  # ignored while the abort is under way.
  class AbortFlag
    attr_reader :reason

    def trip!(reason)
      return if @reason

      @reason = reason
      Thread.main.raise(Aborted.new(reason)) unless @deferred
    end

    # Not an endless def: its one line runs at load, so coverage could
    # never tie it to the specs that call it.
    def tripped?
      !@reason.nil?
    end

    def deferred
      outer = @deferred
      @deferred = true
      raise Aborted, @reason if @reason

      yield
    ensure
      @deferred = outer
    end
  end
end
