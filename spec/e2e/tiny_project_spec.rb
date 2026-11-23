require "json"
require "open3"
require "timeout"
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

  it "exits 143 on SIGTERM mid-run and names what was in flight" do
    Bundler.with_unbundled_env do
      Open3.popen3({ "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
                   "bundle", "exec", "active_mutator", "lib", "--diagnostics", "--jobs", "1",
                   chdir: root) do |stdin, stdout, stderr, wait|
        stdin.close
        drain = Thread.new { stdout.read }
        drain.report_on_exception = false # popen3 closes stdout under it if the spec fails early
        seen = +""
        Timeout.timeout(120) do
          until seen.include?("] mutant start #")
            line = stderr.gets or raise "active_mutator exited before any mutant started:\n#{seen}"
            seen << line
          end
        end
        Process.kill("TERM", wait.pid)
        seen << stderr.read

        expect(wait.value.exitstatus).to eq(143), seen
        expect(drain.value).to include("Run aborted (SIGTERM): partial results", "Partial mutation score:")
        expect(seen).to match(/\] abort sigterm; in flight: /)
        expect(seen).not_to include("] phase mutating end")
      end
    end
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

  it "flags a test that covers killed mutants but never kills one, and ignores a tagged one, with --audit-tests" do
    with_fixture_copy do |copy|
      spec = File.join(copy, "spec", "calculator_spec.rb")
      File.write(spec, File.read(spec).sub(
        %(    it { expect(calc.eligible?(10)).to eq("no") }\n),
        %(    it { expect(calc.eligible?(10)).to eq("no") }\n    it("only calls it") { calc.eligible?(18) }\n) +
        %(    it("calls it on purpose", active_mutator: :no_kill_ok) { calc.eligible?(19) }\n)
      ))

      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(
          { "BUNDLE_GEMFILE" => File.join(copy, "Gemfile") },
          "bundle", "exec", "active_mutator", "--audit-tests", "--format", "json", "--jobs", "2",
          chdir: copy
        )
      end

      data = begin
        JSON.parse(stdout)
      rescue JSON::ParserError
        raise "active_mutator produced unparseable stdout (exit #{status.exitstatus}): " \
              "#{stdout.inspect}\nstderr:\n#{stderr}"
      end
      audit = data.fetch("test_audit")
      expect(audit).not_to be_nil, stderr
      flagged = audit.fetch("no_kills_observed")
      expect(flagged.map { |f| f["id"] }).to eq(["./spec/calculator_spec.rb[1:1:4]"]), stderr
      expect(flagged.first).to include("location" => "./spec/calculator_spec.rb:8", "kills" => 0)
      expect(flagged.first["killable_mutants"]).to be_positive
      expect(audit["ignored"]).to eq(["./spec/calculator_spec.rb[1:1:5]"]), stderr
      expect(audit["mutants_run"]).to be_positive
      expect(status.exitstatus).to eq(1) # unchanged: the planted survivors still fail the run
    end
  end
end
