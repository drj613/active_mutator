require "tmpdir"
require "fileutils"

RSpec.describe ActiveMutator::SinceFilter do
  def git(root, *args)
    system("git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", *args, out: File::NULL, err: File::NULL) \
      or raise "git #{args.first} failed"
  end

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

    it "ignores hunk headers that appear before any +++ file line" do
      diff = <<~DIFF
        @@ -1 +1 @@
        +stray
        +++ b/lib/a.rb
        @@ -2 +2 @@
        +real
      DIFF
      expect(described_class.parse(diff)).to eq("lib/a.rb" => [2])
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

  describe ".touched_files" do
    it "lists every new-side file, including deletion-only ones parse drops" do
      diff = <<~DIFF
        +++ b/lib/a.rb
        @@ -5,2 +4,0 @@
        -gone
        -gone
        +++ b/lib/b.rb
        @@ -1 +1 @@
        -a
        +b
        +++ b/lib/b.rb
        @@ -9 +9 @@
        -c
        +d
      DIFF
      expect(described_class.touched_files(diff)).to eq(["lib/a.rb", "lib/b.rb"])
      expect(described_class.parse(diff).keys).to eq(["lib/b.rb"])
    end
  end

  describe ".deletion_gaps" do
    it "records the new-side line each pure deletion follows" do
      diff = <<~DIFF
        +++ b/lib/a.rb
        @@ -5,2 +4,0 @@
        -gone
        -gone
        @@ -9 +8 @@
        -old
        +new
        +++ b/lib/b.rb
        @@ -1 +0,0 @@
        -first
      DIFF
      expect(described_class.deletion_gaps(diff)).to eq("lib/a.rb" => [4], "lib/b.rb" => [0])
    end
  end

  describe "#cover?" do
    def filter_with_gap(gap)
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, {})
      filter.instance_variable_set(:@gaps, "lib/a.rb" => [gap])
      filter
    end

    let(:method_2_to_5) do
      ActiveMutator::Subject.new(name: "A#x", file: "/root/lib/a.rb", byte_range: 0...1,
                                 line_range: 2..5, constant_scope: "A", kind: :instance)
    end

    it "matches a subject that spans both sides of a deletion" do
      expect(filter_with_gap(2).cover?(method_2_to_5)).to be(true)
      expect(filter_with_gap(4).cover?(method_2_to_5)).to be(true)
    end

    it "does not match a subject that ends or starts right at a deletion" do
      expect(filter_with_gap(5).cover?(method_2_to_5)).to be(false)
      expect(filter_with_gap(1).cover?(method_2_to_5)).to be(false)
    end

    it "matches subjects whose line_range intersects changed lines" do
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, "lib/a.rb" => [11, 12])
      filter.instance_variable_set(:@gaps, {})

      hit = ActiveMutator::Subject.new(name: "A#x", file: "/root/lib/a.rb",
                                     byte_range: 0...1, line_range: 10..14,
                                     constant_scope: "A", kind: :instance)
      miss = hit.with(line_range: 20..24)
      other_file = hit.with(file: "/root/lib/z.rb")

      expect(filter.cover?(hit)).to be(true)
      expect(filter.cover?(miss)).to be(false)
      expect(filter.cover?(other_file)).to be(false)
    end
  end

  describe "#changed_files" do
    it "lists tracked .rb files with hunks and untracked .rb files, root-relative" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 1\nend\n")
        File.write(File.join(root, "lib", "same.rb"), "class Same; end\n")
        File.write(File.join(root, "README.md"), "hi\n")
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")

        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 2\nend\n")
        File.write(File.join(root, "lib", "new.rb"), "class New; end\n")
        File.write(File.join(root, "README.md"), "changed docs\n")
        File.write(File.join(root, "notes.txt"), "untracked non-ruby\n")

        filter = described_class.new(ref: "HEAD", root: root)
        expect(filter.changed_files).to contain_exactly("lib/a.rb", "lib/new.rb")
      end
    end

    it "includes a file whose only change is a deletion" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a\n    return 0 if @x\n    1\n  end\nend\n")
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a\n    1\n  end\nend\n")

        filter = described_class.new(ref: "HEAD", root: root)
        expect(filter.changed_files).to eq(["lib/a.rb"])
      end
    end

    it "covers the method a deletion was made inside, but not its neighbors" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "lib"))
        source = "class A\n  def a\n    return 0 if @x\n    1\n  end\n\n  def b = 2\nend\n"
        File.write(File.join(root, "lib", "a.rb"), source)
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")
        File.write(File.join(root, "lib", "a.rb"), source.sub("    return 0 if @x\n", ""))

        filter = described_class.new(ref: "HEAD", root: root)
        a = ActiveMutator::Subject.new(name: "A#a", file: File.join(root, "lib", "a.rb"), byte_range: 0...1,
                                       line_range: 2..4, constant_scope: "A", kind: :instance)
        expect(filter.cover?(a)).to be(true)
        expect(filter.cover?(a.with(name: "A#b", line_range: 6..6))).to be(false)
        expect(filter.deletion_only?("lib/a.rb")).to be(true)
      end
    end

    it "is not deletion-only when lines were added" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 1\nend\n")
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 2\nend\n")
        File.write(File.join(root, "lib", "new.rb"), "class New; end\n")

        filter = described_class.new(ref: "HEAD", root: root)
        expect(filter.deletion_only?("lib/a.rb")).to be(false)
        expect(filter.deletion_only?("lib/new.rb")).to be(false)
      end
    end

    it "covers subjects in the real repo by root-relative path" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 1\nend\n")
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 2\nend\n")

        filter = described_class.new(ref: "HEAD", root: root)
        hit = ActiveMutator::Subject.new(name: "A#a", file: File.join(root, "lib", "a.rb"),
                                       byte_range: 0...1, line_range: 2..2,
                                       constant_scope: "A", kind: :instance)
        expect(filter.cover?(hit)).to be(true)
        expect(filter.cover?(hit.with(line_range: 3..3))).to be(false)
      end
    end

    it "raises Error when the ref does not resolve" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "a.rb"), "1\n")
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")
        expect { described_class.new(ref: "no-such-ref", root: root) }
          .to raise_error(ActiveMutator::Error, /git diff no-such-ref failed/)
      end
    end

    it "is empty when nothing changed" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "a.rb"), "1\n")
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "base")
        expect(described_class.new(ref: "HEAD", root: root).changed_files).to eq([])
      end
    end
  end

  describe ".same_code?" do
    let(:base) { "class A\n  def x\n    1\n  end\nend\n" }

    it "is true when only comments and blank lines changed" do
      edited = "# top\nclass A\n  # doc\n  def x\n\n    1 # trailing\n  end\n=begin\nblock\n=end\nend"
      expect(described_class.same_code?(base, edited)).to be(true)
    end

    it "is true when comments were only deleted" do
      expect(described_class.same_code?("# old note\n#{base}", base)).to be(true)
    end

    it "is false when code changed" do
      expect(described_class.same_code?(base, base.sub("1", "2"))).to be(false)
    end

    it "is false when a comment-looking line inside a heredoc changed" do
      a = "X = <<~T\n  # one\nT\n"
      expect(described_class.same_code?(a, a.sub("one", "two"))).to be(false)
    end

    it "is false when a magic comment changed" do
      expect(described_class.same_code?(base, "# frozen_string_literal: true\n#{base}")).to be(false)
    end

    it "is false when either side fails to parse" do
      expect(described_class.same_code?(base, "#{base}end\n")).to be(false)
    end

    it "is false when both sides fail to parse, even if only a comment differs" do
      broken = "def x(\n"
      expect(described_class.same_code?(broken, "# note\n#{broken}")).to be(false)
    end

    it "is false when a line break moved" do
      expect(described_class.same_code?("a\nb\n", "a b\n")).to be(false)
    end

    it "is true when an unchanged magic comment sits beside the edited comments" do
      magic = "# frozen_string_literal: true\n"
      expect(described_class.same_code?("#{magic}#{base}", "#{magic}# note\n#{base}")).to be(true)
    end
  end

  describe "#comment_only?" do
    def repo_with(root, source)
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib", "a.rb"), source)
      git(root, "init", "-q")
      git(root, "add", "-A")
      git(root, "commit", "-qm", "base")
    end

    it "is true when the file gained only a comment since the ref" do
      Dir.mktmpdir do |root|
        repo_with(root, "class A\n  def a = 1\nend\n")
        File.write(File.join(root, "lib", "a.rb"), "class A\n  # note\n  def a = 1\nend\n")
        expect(described_class.new(ref: "HEAD", root: root).comment_only?("lib/a.rb")).to be(true)
      end
    end

    it "is false when code changed since the ref" do
      Dir.mktmpdir do |root|
        repo_with(root, "class A\n  def a = 1\nend\n")
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 2\nend\n")
        expect(described_class.new(ref: "HEAD", root: root).comment_only?("lib/a.rb")).to be(false)
      end
    end

    it "compares against the ref, not the staged copy" do
      Dir.mktmpdir do |root|
        repo_with(root, "class A\n  def a = 1\nend\n")
        File.write(File.join(root, "lib", "a.rb"), "class A\n  def a = 2\nend\n")
        git(root, "add", "-A")
        expect(described_class.new(ref: "HEAD", root: root).comment_only?("lib/a.rb")).to be(false)
      end
    end

    it "is true for an untracked file holding only comments" do
      Dir.mktmpdir do |root|
        repo_with(root, "class A; end\n")
        File.write(File.join(root, "lib", "notes.rb"), "# TODO: fill in\n")
        expect(described_class.new(ref: "HEAD", root: root).comment_only?("lib/notes.rb")).to be(true)
      end
    end

    it "is false for an untracked file with code" do
      Dir.mktmpdir do |root|
        repo_with(root, "class A; end\n")
        File.write(File.join(root, "lib", "new.rb"), "# new\nclass New; end\n")
        expect(described_class.new(ref: "HEAD", root: root).comment_only?("lib/new.rb")).to be(false)
      end
    end
  end

  describe "untracked files" do
    it "treats untracked files as fully changed (whole-file sentinel)" do
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, "lib/new.rb" => :all)

      subject_ = ActiveMutator::Subject.new(name: "N#x", file: "/root/lib/new.rb",
                                          byte_range: 0...1, line_range: 500..510,
                                          constant_scope: "N", kind: :instance)
      expect(filter.cover?(subject_)).to be(true)
    end
  end
end
