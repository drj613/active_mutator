module ActiveMutator
  # Internal event bus for run diagnostics. Producers call
  # `emit(type, **fields)`; listeners get a frozen Event. With no listeners
  # emit returns at once, so a default run pays nothing. Not a public hook
  # API: the NDJSON file (--events) is the public contract.
  class Events
    # at: wall time; elapsed: monotonic seconds since the bus was built.
    Event = Data.define(:type, :at, :elapsed, :fields)

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, wall: -> { Time.now })
      @clock = clock
      @wall = wall
      @started = clock.call
      @listeners = []
      # The memory sampler emits from its own thread.
      @lock = Mutex.new
    end

    # A listener is anything with #call(event), or a block.
    def subscribe(listener = nil, &block)
      @listeners << (listener || block)
      self
    end

    def listening? = !@listeners.empty?

    # Emits phase_start, runs the block, emits phase_end, and returns the
    # block's value. A phase that raises gets no phase_end, so the last
    # unmatched phase_start marks where a run died.
    def phase(name, **fields)
      emit(:phase_start, phase: name, **fields)
      result = yield
      emit(:phase_end, phase: name)
      result
    end

    def emit(type, **fields)
      return if @listeners.empty?

      @lock.synchronize do
        event = Event.new(type: type, at: @wall.call, elapsed: @clock.call - @started, fields: fields.freeze)
        @listeners.each { |listener| listener.call(event) }
      end
      nil
    end
  end
end
