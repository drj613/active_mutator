module ActiveMutator
  # lane: :parallel (default pool) | :serial (browser-covered, one at a time)
  WorkItem = Data.define(:mutation, :example_ids, :timeout, :lane)
end
