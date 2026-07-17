module ActiveMutator
  # lane: :parallel (default pool) | :serial (browser-covered, one at a time)
  # timeout:    static total budget (variable + fixed), kept for --debug-plan and compat
  # variable:   the baseline-estimate-derived part (estimate * timeout_factor) — the
  #             only part the TimeoutCalibrator scales
  # boot_extra: browser_boot_seconds for the serial lane, 0.0 otherwise (always additive)
  WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane, :variable, :boot_extra) do
    def initialize(mutation:, example_ids:, timeout:, lane:, variable: 0.0, boot_extra: 0.0)
      super
    end
  end
end
