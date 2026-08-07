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

  it "finds specs under test/ with --spec-path" do
    with_fixture_copy do |copy|
      FileUtils.mv(File.join(copy, "spec"), File.join(copy, "test"))
      # A project with specs under test/ configures rspec's own discovery
      # itself; --spec-path tells active_mutator, --default-path tells rspec.
      File.write(File.join(copy, ".rspec"),
                 "--default-path test\n--require ./test/spec_helper\n")

      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(
          { "BUNDLE_GEMFILE" => File.join(copy, "Gemfile") },
          "bundle", "exec", "active_mutator", "lib", "--spec-path", "test",
          "--format", "json", "--jobs", "2",
          chdir: copy
        )
      end

      data = begin
        JSON.parse(stdout)
      rescue JSON::ParserError
        raise "active_mutator produced unparseable stdout (exit #{status.exitstatus}): " \
              "#{stdout.inspect}\nstderr:\n#{stderr}"
      end
      results = data.fetch("results")

      killed = results.select { |r| r["status"] == "killed" }
      expect(killed).not_to be_empty, stderr
      expect(results.map { |r| r["status"] }).to include("survived")
    end
  end
end
