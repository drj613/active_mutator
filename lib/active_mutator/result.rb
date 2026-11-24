module ActiveMutator
  # status: :killed | :survived | :timeout | :error | :uncovered | :accepted | :skipped
  # seconds: worker wall time; peak_rss_kb: the worker's own peak RSS (nil
  # off Linux). Both nil for results that never ran in a worker.
  # killed_by: the example ids that killed it, as RSpec spells them. The
  # normal run stops at the first failure, so it names at most one; empty
  # when no example is to blame (e.g. the mutated class failed to load).
  # passed: id => location for each example that passed; only audit workers
  # report it (#54), so it is empty everywhere else. ignored: the ids of
  # passing examples tagged `active_mutator: :no_kill_ok`, also audit-only.
  Result = Data.define(:mutation, :status, :details, :seconds, :peak_rss_kb, :killed_by, :passed, :ignored, :carried) do
    def initialize(mutation:, status:, details:, seconds: nil, peak_rss_kb: nil, killed_by: [], passed: {},
                   ignored: [], carried: false)
      super
    end

    def detected? = %i[killed timeout].include?(status)
  end
end
