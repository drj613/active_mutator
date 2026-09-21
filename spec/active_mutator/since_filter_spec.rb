require "tmpdir"
require "fileutils"

RSpec.describe ActiveMutator::SinceFilter do
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

  describe "#cover?" do
    it "matches subjects whose line_range intersects changed lines" do
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, "lib/a.rb" => [11, 12])

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
    def git(root, *args)
      system("git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", *args, out: File::NULL, err: File::NULL) \
        or raise "git #{args.first} failed"
    end

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
