module ActiveMutator
  # One concrete mutant. `line` is the 1-based line of the edit in the
  # ORIGINAL file (used for coverage lookup and reporting).
  Mutation = Data.define(:subject, :edit, :original_snippet, :line,
                         :mutated_file_source, :mutated_def_source, :mutated_def_line) do
    def description = edit.description

    # Original-file lines the edit touches (edit may span lines).
    def lines = line..(line + original_snippet.count("\n"))
  end
end
