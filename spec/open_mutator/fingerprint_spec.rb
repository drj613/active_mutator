RSpec.describe OpenMutator::Fingerprint do
  def mutation(desc, snippet, range_begin, subject_name: "Calc#go", file: "/root/lib/calc.rb")
    subject_ = OpenMutator::Subject.new(name: subject_name, file: file, byte_range: 0...100,
                                        line_range: 1..10, constant_scope: "Calc", kind: :instance)
    OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: range_begin...(range_begin + 1), replacement: "x", description: desc),
      original_snippet: snippet, line: 2,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 1
    )
  end

  it "assigns ordinals to identical mutants in source order" do
    m1 = mutation("replace `>` with `>=`", ">", 10)
    m2 = mutation("replace `>` with `>=`", ">", 30)
    m3 = mutation("force condition to `true`", "a > 0", 5)
    fps = described_class.for_mutations([m2, m3, m1], root: "/root")
    expect(fps[m1].ordinal).to eq(0)   # earlier byte offset
    expect(fps[m2].ordinal).to eq(1)
    expect(fps[m3].ordinal).to eq(0)
    expect(fps[m1]).not_to eq(fps[m2]) # collision resolved
    expect(fps[m1].file).to eq("lib/calc.rb") # relative, portable
  end
end
