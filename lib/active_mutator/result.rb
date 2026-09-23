module ActiveMutator
  # status: :killed | :survived | :timeout | :error | :uncovered | :accepted | :skipped
  # seconds: worker wall time; peak_rss_kb: the worker's own peak RSS (nil
  # off Linux). Both nil for results that never ran in a worker.
  Result = Data.define(:mutation, :status, :details, :seconds, :peak_rss_kb) do
    def initialize(mutation:, status:, details:, seconds: nil, peak_rss_kb: nil)
      super
    end

    def detected? = %i[killed timeout].include?(status)
  end
end
