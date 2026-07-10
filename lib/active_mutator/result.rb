module ActiveMutator
  # status: :killed | :survived | :timeout | :error | :uncovered | :accepted
  Result = Data.define(:mutation, :status, :details) do
    def detected? = %i[killed timeout].include?(status)
  end
end
