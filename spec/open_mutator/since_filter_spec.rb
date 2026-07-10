RSpec.describe OpenMutator::SinceFilter do
  describe ".parse" do
    it "extracts added/changed line numbers per file from unified=0 diffs" do
      diff = <<~DIFF
        diff --git a/lib/a.rb b/lib/a.rb
        --- a/lib/a.rb
        +++ b/lib/a.rb
        @@ -10,0 +11,2 @@ def x
        +  new_line_11
        +  new_line_12
        @@ -20 +22 @@ def y
        -  old
        +  changed_22
        diff --git a/lib/b.rb b/lib/b.rb
        --- a/lib/b.rb
        +++ b/lib/b.rb
        @@ -1 +1 @@
        -a
        +b
      DIFF
      expect(described_class.parse(diff)).to eq(
        "lib/a.rb" => [11, 12, 22],
        "lib/b.rb" => [1]
      )
    end

    it "ignores pure deletions (zero new-side count)" do
      diff = <<~DIFF
        +++ b/lib/a.rb
        @@ -5,2 +4,0 @@
        -gone
        -gone
      DIFF
      expect(described_class.parse(diff)).to eq({})
    end
  end

  describe "#cover?" do
    it "matches subjects whose line_range intersects changed lines" do
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, "lib/a.rb" => [11, 12])

      hit = OpenMutator::Subject.new(name: "A#x", file: "/root/lib/a.rb",
                                     byte_range: 0...1, line_range: 10..14,
                                     constant_scope: "A", kind: :instance)
      miss = hit.with(line_range: 20..24)
      other_file = hit.with(file: "/root/lib/z.rb")

      expect(filter.cover?(hit)).to be(true)
      expect(filter.cover?(miss)).to be(false)
      expect(filter.cover?(other_file)).to be(false)
    end
  end

  describe "untracked files" do
    it "treats untracked files as fully changed (whole-file sentinel)" do
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, "lib/new.rb" => :all)

      subject_ = OpenMutator::Subject.new(name: "N#x", file: "/root/lib/new.rb",
                                          byte_range: 0...1, line_range: 500..510,
                                          constant_scope: "N", kind: :instance)
      expect(filter.cover?(subject_)).to be(true)
    end
  end
end
