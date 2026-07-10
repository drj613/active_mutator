RSpec.describe OpenMutator::BaselineDelta do
  let(:root) { "/project" }

  def coverage_map(records)
    OpenMutator::CoverageMap.new("version" => 2, "records" => records, "times" => {}, "digests" => {})
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
end
