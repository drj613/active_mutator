module ActiveMutator
  # lane: :parallel (default pool) | :serial (browser-covered, one at a time)
  # timeout:    static total budget (variable + fixed), kept for --debug-plan and compat
  # variable:   the baseline-estimate-derived part (estimate * timeout_factor) — the
  #             only part the TimeoutCalibrator scales
  WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane, :variable) do
    def initialize(mutation:, example_ids:, timeout:, lane:, variable: 0.0)
      super
    end
  end
end
