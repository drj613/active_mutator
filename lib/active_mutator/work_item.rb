module ActiveMutator
  # lane: :parallel (default pool) | :serial (browser-covered, one at a time)
  # timeout:    static total budget (variable + fixed), kept for --debug-plan and compat
  # example_ids: the covering set in run priority. A worker loads the specs
  #             sorted but runs top-level groups in this order.
  # variable:   the baseline-estimate-derived part (estimate * timeout_factor) — the
  #             only part the TimeoutCalibrator scales
  WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane, :variable) do
    def initialize(mutation:, example_ids:, timeout:, lane:, variable: 0.0)
      super
    end
  end
end
