module OpenMutator
  # status: :killed | :survived | :timeout | :error | :uncovered
  Result = Data.define(:mutation, :status, :details) do
    def detected? = %i[killed timeout].include?(status)
  end
end
