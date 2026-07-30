module ActiveMutator
  # status: :killed | :survived | :timeout | :error | :uncovered | :accepted | :skipped
  Result = Data.define(:mutation, :status, :details) do
    def detected? = %i[killed timeout].include?(status)
  end
end
