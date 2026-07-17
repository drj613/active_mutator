RSpec.describe ActiveMutator::BaselineDelta do
  let(:root) { "/project" }

  def coverage_map(records)
    ActiveMutator::CoverageMap.new("version" => 2, "records" => records, "times" => {}, "digests" => {})
  end

  let(:records) do
    {
      "./spec/a_spec.rb[1:1]" => [["/project/lib/a.rb", 3]],
      "./spec/b_spec.rb[1:1]" => [["/project/lib/b.rb", 9]]
    }
  end

  def compute(old_d, new_d, recs: records)
    described_class.compute(old_digests: old_d, new_digests: new_d,
                            coverage_map: coverage_map(recs), root: root)
  end

  it "is empty when nothing changed" do
    d = { "lib/a.rb" => "x" }
    delta = compute(d, d)
    expect(delta.full?).to be(false)
    expect(delta.rerun_spec_files).to eq([])
    expect(delta.rerun_example_ids).to eq([])
  end

  it "re-runs a changed spec file" do
    delta = compute({ "spec/a_spec.rb" => "x" }, { "spec/a_spec.rb" => "y" })
    expect(delta.full?).to be(false)
    expect(delta.rerun_spec_files).to eq(["spec/a_spec.rb"])
  end

  it "re-runs a NEW spec file" do
    delta = compute({}, { "spec/new_spec.rb" => "y" })
    expect(delta.rerun_spec_files).to eq(["spec/new_spec.rb"])
  end

  it "re-runs examples covering a changed source file" do
    delta = compute({ "lib/a.rb" => "x" }, { "lib/a.rb" => "y" })
    expect(delta.rerun_example_ids).to eq(["./spec/a_spec.rb[1:1]"])
  end

  it "drops records for a deleted spec file that owned records" do
    delta = compute({ "spec/a_spec.rb" => "x" }, {})
    expect(delta.full?).to be(false)
    expect(delta.drop_example_ids).to eq(["./spec/a_spec.rb[1:1]"])
  end

  it "drops a deleted source file from records" do
    delta = compute({ "lib/a.rb" => "x" }, {})
    expect(delta.drop_source_files).to eq(["/project/lib/a.rb"])
  end

  it "does not drop a source file that changed but still exists" do
    delta = compute({ "lib/a.rb" => "x" }, { "lib/a.rb" => "y" })
    expect(delta.drop_source_files).to eq([])
  end

  it "does not re-run examples for an added source file" do
    delta = compute({}, { "lib/a.rb" => "y" })
    expect(delta.rerun_example_ids).to eq([])
  end

  it "treats spec/support paths themselves as full triggers" do
    expect(described_class.full_trigger?("spec/support/helpers.rb")).to be(true)
    expect(described_class.full_trigger?("spec/a_spec.rb")).to be(false)
  end

  it "goes full for any spec/support change" do
    expect(compute({ "spec/support/helpers.rb" => "x" }, { "spec/support/helpers.rb" => "y" }).full?).to be(true)
    expect(compute({ "spec/support/helpers.rb" => "x" }, {}).full?).to be(true)
  end

  it "goes full for a pre-existing changed spec file that owns no records (support-like)" do
    delta = compute({ "spec/shared_stuff.rb" => "x" }, { "spec/shared_stuff.rb" => "y" })
    expect(delta.full?).to be(true)
  end

  it "goes full for a deleted spec file that owned no records" do
    expect(compute({ "spec/shared_stuff.rb" => "x" }, {}).full?).to be(true)
  end

  it "goes full when non-rb keys change (Gemfile.lock, .rspec)" do
    expect(compute({ "Gemfile.lock" => "x" }, { "Gemfile.lock" => "y" }).full?).to be(true)
    expect(compute({ ".rspec" => "x" }, { ".rspec" => "y" }).full?).to be(true)
  end

  describe "newly-covering candidates (#11)" do
    require "fileutils"
    require "tmpdir"

    def project(files)
      Dir.mktmpdir do |dir|
        files.each do |rel, content|
          abs = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(abs))
          File.write(abs, content)
        end
        yield dir
      end
    end

    it "re-runs an unchanged spec file that references the changed constant but covers none of it" do
      project(
        "lib/invoice.rb" => "class Invoice; def total; 1; end; end\n",
        "spec/invoice_shared_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/other_spec.rb" => "RSpec.describe Object do; end\n"
      ) do |root|
        recs = { "./spec/other_spec.rb[1:1]" => [[File.join(root, "lib/other.rb"), 1]] }
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map(recs), root: root
        )
        expect(delta.full?).to be(false)
        expect(delta.rerun_spec_files).to eq(["spec/invoice_shared_spec.rb"])
      end
    end

    it "does not re-run a referencing spec file that already covers the changed file" do
      project(
        "lib/invoice.rb" => "class Invoice; def total; 1; end; end\n",
        "spec/invoice_spec.rb" => "RSpec.describe Invoice do; end\n"
      ) do |root|
        recs = { "./spec/invoice_spec.rb[1:1]" => [[File.join(root, "lib/invoice.rb"), 1]] }
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map(recs), root: root
        )
        expect(delta.rerun_spec_files).to eq([])
        expect(delta.rerun_example_ids).to eq(["./spec/invoice_spec.rb[1:1]"])
      end
    end

    it "scans newly added source files too" do
      project(
        "lib/invoice.rb" => "class Invoice; end\n",
        "spec/invoice_shared_spec.rb" => "RSpec.describe Invoice do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: {}, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.rerun_spec_files).to eq(["spec/invoice_shared_spec.rb"])
      end
    end

    it "falls back to a full run when the referencing set exceeds half of all spec files" do
      project(
        "lib/invoice.rb" => "class Invoice; end\n",
        "spec/a_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/b_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/c_spec.rb" => "RSpec.describe Object do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.full?).to be(true)
      end
    end

    it "ignores deleted source files (nothing on disk to scan)" do
      project("spec/a_spec.rb" => "RSpec.describe Invoice do; end\n") do |root|
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: {},
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.rerun_spec_files).to eq([])
      end
    end

    it "warns when the reference scan trips the full-run fallback (never silent)" do
      project(
        "lib/invoice.rb" => "class Invoice; end\n",
        "spec/a_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/b_spec.rb" => "RSpec.describe Invoice do; end\n"
      ) do |root|
        expect do
          described_class.compute(
            old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
            coverage_map: coverage_map({}), root: root
          )
        end.to output(/constant-reference scan matched 2 of 2 spec files.*falling back to full baseline/)
          .to_stderr
      end
    end

    it "does not blow up incremental mode for common leaf names or ubiquitous namespace tokens" do
      # DefinedConstants (Task 8) emits only "MyApp::Config" here: neither the
      # bare leaf "Config" nor the pure wrapper "MyApp" is matched. In a
      # namespaced app every spec mentions the top module, so matching either
      # token would trip the full-run fallback on every edit.
      project(
        "lib/my_app/config.rb" => "module MyApp; class Config; end; end\n",
        "spec/a_spec.rb" => "RSpec.describe \"a\" do; end # bare Config and MyApp mentioned\n",
        "spec/b_spec.rb" => "RSpec.describe \"b\" do; end # bare Config and MyApp mentioned\n",
        "spec/c_spec.rb" => "RSpec.describe MyApp::Config do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/my_app/config.rb" => "x" },
          new_digests: { "lib/my_app/config.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.full?).to be(false)
        expect(delta.rerun_spec_files).to eq(["spec/c_spec.rb"])
      end
    end

    it "does not scan a deleted source file even when it still exists on disk" do
      project(
        "lib/invoice.rb" => "class Invoice; def total; 1; end; end\n",
        "spec/invoice_shared_spec.rb" => "RSpec.describe Invoice do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: {},
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.rerun_spec_files).to eq([])
        expect(delta.drop_source_files).to eq([File.join(root, "lib/invoice.rb")])
      end
    end

    it "scans nothing when the changed source file defines no constants" do
      project(
        "lib/plain.rb" => "PLAIN = 1\n",
        "spec/plain_shared_spec.rb" => "RSpec.describe Object do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/plain.rb" => "x" }, new_digests: { "lib/plain.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.full?).to be(false)
        expect(delta.rerun_spec_files).to eq([])
      end
    end

    it "matches any one of several defined constants (alternation, not concatenation)" do
      project(
        "lib/pair.rb" => "class Invoice; end\nclass Widget; end\n",
        "spec/widget_only_spec.rb" => "RSpec.describe Widget do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/pair.rb" => "x" }, new_digests: { "lib/pair.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.rerun_spec_files).to eq(["spec/widget_only_spec.rb"])
      end
    end

    it "keeps a partial re-run (no fallback) at exactly the half-of-all-specs boundary" do
      project(
        "lib/invoice.rb" => "class Invoice; end\n",
        "spec/a_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/b_spec.rb" => "RSpec.describe Invoice do; end\n",
        "spec/c_spec.rb" => "RSpec.describe Object do; end\n",
        "spec/d_spec.rb" => "RSpec.describe Object do; end\n"
      ) do |root|
        delta = described_class.compute(
          old_digests: { "lib/invoice.rb" => "x" }, new_digests: { "lib/invoice.rb" => "y" },
          coverage_map: coverage_map({}), root: root
        )
        expect(delta.full?).to be(false)
        expect(delta.rerun_spec_files).to eq(["spec/a_spec.rb", "spec/b_spec.rb"])
      end
    end
  end
end
