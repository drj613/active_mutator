require "json"
require "open3"
require "fileutils"

RSpec.describe "tiny_project end-to-end", :e2e do
  let(:root) { File.expand_path("../fixtures/tiny_project", __dir__) }

  before { ensure_fixture_bundle! }
  after { FileUtils.rm_rf(File.join(root, ".active_mutator")) }

  it "kills tested mutants, surfaces the planted survivor and uncovered method" do
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
        "bundle", "exec", "active_mutator", "lib", "--format", "json", "--jobs", "2",
        chdir: root
      )
    end

    data = begin
      JSON.parse(stdout)
    rescue JSON::ParserError
      raise "active_mutator produced unparseable stdout (exit #{status.exitstatus}): " \
            "#{stdout.inspect}\nstderr:\n#{stderr}"
    end
    results = data.fetch("results")

    survivors = results.select { |r| r["status"] == "survived" }
    expect(survivors.map { |r| [r["subject"], r["description"]] })
      .to contain_exactly(
        ["Calculator#discount", "replace `<` with `<=`"],
        ["Calculator#discount", "replace `100` with `101`"]
      ), stderr

    eligible = results.select { |r| r["subject"] == "Calculator#eligible?" }
    expect(eligible).not_to be_empty
    expect(eligible.map { |r| r["status"] }.uniq).to eq(["killed"])

    uncovered = results.select { |r| r["status"] == "uncovered" }
    expect(uncovered.map { |r| r["subject"] }.uniq).to eq(["Calculator#untested_helper"])

    expect(status.exitstatus).to eq(1) # survivors present
  end
end
