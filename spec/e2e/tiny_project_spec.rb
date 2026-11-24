require "json"
require "open3"
require "timeout"
require "fileutils"

RSpec.describe "tiny_project end-to-end", :e2e do
  let(:root) { File.expand_path("../fixtures/tiny_project", __dir__) }

  before { ensure_fixture_bundle! }
  after { FileUtils.rm_rf(File.join(root, ".active_mutator")) }

  def run_json(dir, *flags)
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(dir, "Gemfile") },
        "bundle", "exec", "active_mutator", "--format", "json", "--jobs", "1", *flags,
        chdir: dir
      )
    end
    raise stderr unless [0, 1].include?(status.exitstatus) && !stdout.empty?
    JSON.parse(stdout)
  end

  it "persists verified killers across a forced baseline" do
    run_json(root)
    path = File.join(root, ".active_mutator", "killers.json")
    expect(JSON.parse(File.read(path)).values).to include(a_string_matching(/calculator_spec.rb/))
    run_json(root, "--force-baseline")
    expect(JSON.parse(File.read(path))).not_to be_empty
  end

  it "carries kills and survivors and invalidates only affected work" do
    with_fixture_copy do |copy|
      File.write(File.join(copy, "lib", "counter.rb"), <<~RUBY)
        class Counter
          def count
            2
          end
        end
      RUBY
      File.open(File.join(copy, "spec", "spec_helper.rb"), "a") do |file|
        file.puts 'require_relative "../lib/counter"'
      end
      counter_spec = File.join(copy, "spec", "counter_spec.rb")
      File.write(counter_spec, <<~RUBY)
        require_relative "../lib/counter"
        RSpec.describe Counter do
          it { expect(Counter.new.count).to eq(2) }
        end
      RUBY

      first = run_json(copy, "--incremental")
      second = run_json(copy, "--incremental", "--events", "events.ndjson")
      events = File.readlines(File.join(copy, "events.ndjson")).map { |line| JSON.parse(line).fetch("event") }
      expect(events).not_to include("mutant_start")
      expect(second.fetch("counts")).to eq(first.fetch("counts"))
      eligible = second.fetch("results").select { |r| %w[killed survived].include?(r.fetch("status")) }
      expect(eligible.map { |r| r["carried"] }).to all(be(true))
      expect(second.fetch("carried")).to eq(eligible.size)
      expect(eligible.map { |r| r["seconds"] }).to all(be_nil)

      File.open(File.join(copy, "lib", "calculator.rb"), "a") { |file| file.puts "# source edit" }
      third = run_json(copy, "--incremental")
      carried_subjects = third.fetch("results").select { |r| r["carried"] }.map { |r| r["subject"] }.uniq
      expect(carried_subjects).to eq(["Counter#count"]), third.fetch("results").inspect

      File.open(counter_spec, "a") { |file| file.puts "# spec edit" }
      fourth = run_json(copy, "--incremental")
      counter = fourth.fetch("results").find { |r| r["subject"] == "Counter#count" }
      expect(counter["carried"]).to be(false)
      expect(fourth.fetch("results").any? { |r| r["carried"] }).to be(true)
    end
  end

  it "reports mutations when the warm cache is read-only" do
    run_json(root)
    cache = File.join(root, ".active_mutator")
    File.chmod(0o555, cache)
    expect(run_json(root).fetch("counts").fetch("killed")).to be_positive
  ensure
    File.chmod(0o755, cache) if cache && File.directory?(cache)
  end

  def write_limit_fixture(copy)
    File.write(File.join(copy, "lib/calculator.rb"), <<~RUBY)
      class Calculator
        def over?(n)
          n > 10
        end
      end
    RUBY
    File.write(File.join(copy, "spec/calculator_spec.rb"), <<~RUBY)
      require "json"
      RSpec.describe Calculator do
        JSON.parse(File.read(File.join(__dir__, "cases.json"))).each do |n, expected|
          it(n.to_s) { expect(Calculator.new.over?(n)).to eq(expected) }
        end
      end
    RUBY
    write_cases(copy, 10)
  end

  def write_cases(copy, boundary_case)
    File.write(File.join(copy, "spec/cases.json"), JSON.generate([[11, true], [boundary_case, false]]))
  end

  def boundary_result(report)
    report.fetch("results").find { |result| result["replacement"] == ">=" }
  end

  it "invalidates verdicts when a spec data file changes" do
    with_fixture_copy do |copy|
      write_limit_fixture(copy)
      expect(boundary_result(run_json(copy, "--incremental"))).to include("status" => "killed")
      write_cases(copy, 5)
      expect(boundary_result(run_json(copy, "--incremental")))
        .to include("status" => "survived", "carried" => false)
    end
  end

  it "invalidates verdicts when an extensionless require changes" do
    with_fixture_copy do |copy|
      write_limit_fixture(copy)
      mode = File.join(copy, "mode.rb")
      File.write(mode, "LIMIT_EDGE = 10")
      spec = File.join(copy, "spec/calculator_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe Calculator do
          it { expect(Calculator.new.over?(defined?(LIMIT_EDGE) ? LIMIT_EDGE : 10)).to be(false) }
        end
      RUBY
      flags = %w[--incremental --require mode]
      expect(boundary_result(run_json(copy, *flags))).to include("status" => "killed")
      File.write(mode, "LIMIT_EDGE = 5")
      expect(boundary_result(run_json(copy, *flags))).to include("status" => "survived", "carried" => false)
    end
  end

  it "invalidates coverage and verdicts together when RSpec setup changes" do
    with_fixture_copy do |copy|
      write_limit_fixture(copy)
      File.write(File.join(copy, ".rspec-local"), "--require ./mode.rb\n")
      mode = File.join(copy, "mode.rb")
      File.write(mode, "CHECK_BOUNDARY = true")
      File.write(File.join(copy, "spec/calculator_spec.rb"), <<~RUBY)
        RSpec.describe Calculator do
          let(:check_boundary) { !defined?(CHECK_BOUNDARY) || CHECK_BOUNDARY }
          it("exercises the method") { Calculator.new.over?(11) unless check_boundary }
          it("checks the boundary") { expect(Calculator.new.over?(10)).to be(false) if check_boundary }
        end
      RUBY
      expect(boundary_result(run_json(copy, "--incremental"))).to include("status" => "killed")
      File.write(mode, "CHECK_BOUNDARY = false")
      expect(boundary_result(run_json(copy, "--incremental")))
        .to include("status" => "survived", "carried" => false)
      File.unlink(File.join(copy, ".rspec-local"))
      expect(boundary_result(run_json(copy, "--incremental", "--force-baseline")))
        .to include("status" => "killed", "carried" => false)
    end
  end

  it "rebuilds a coverage map restored at a different checkout path" do
    with_fixture_copy do |copy|
      first = run_json(copy, "--incremental")
      relocated = File.join(File.dirname(copy), "relocated")
      FileUtils.cp_r(copy, relocated)
      expect(run_json(relocated, "--incremental").fetch("counts")).to eq(first.fetch("counts"))
    end
  end

  it "keeps unrelated verdicts after a scoped incremental run" do
    with_fixture_copy do |copy|
      run_json(copy, "--incremental")
      run_json(copy, "--incremental", "--subject", "Calculator#eligible?")
      full = run_json(copy, "--incremental")
      eligible = full.fetch("results").select { |r| %w[killed survived].include?(r.fetch("status")) }
      expect(eligible.map { |r| r["carried"] }).to all(be(true))
    end
  end

  it "does not publish a verdict under a source digest newer than its plan" do
    with_fixture_copy do |copy|
      File.write(File.join(copy, "lib/calculator.rb"), <<~RUBY)
        class Calculator
          def value(n)
            n > 0 ? 1 : 2
          end
        end
      RUBY
      File.write(File.join(copy, "spec/calculator_spec.rb"), <<~RUBY)
        RSpec.describe Calculator do
          it { expect(Calculator.new.value(1)).to eq(1) }
        end
      RUBY
      hook = <<~'RUBY'
        require "active_mutator"
        events = ActiveMutator::Events.new.subscribe do |event|
          next unless event.type == :phase_end && event.fields[:phase] == :planning

          path = "lib/calculator.rb"
          File.write(path, File.read(path).sub("? 1 : 2", "? 1 : 1"))
        end
        config = ActiveMutator::CLI.parse(%w[--incremental --format json --jobs 1])
        exit ActiveMutator::Runner.new(config, events: events).call
      RUBY
      Bundler.with_unbundled_env do
        _, stderr, status = Open3.capture3(
          { "BUNDLE_GEMFILE" => File.join(copy, "Gemfile") },
          "bundle", "exec", "ruby", "-e", hook, chdir: copy
        )
        expect(status.exitstatus).to be_between(0, 1), stderr
      end
      condition = run_json(copy, "--incremental").fetch("results").find { |r| r["replacement"] == "false" }
      expect(condition).to include("status" => "survived", "carried" => false)
    end
  end

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
      run_json(copy, "--incremental", "--audit-tests")
      carried = run_json(copy, "--incremental", "--audit-tests")
      carried_audit = carried.fetch("test_audit")
      expect(carried.fetch("carried")).to be_positive
      expect(carried_audit).to eq(audit.merge("mutants_run" => 0))
      expect(status.exitstatus).to eq(1) # unchanged: the planted survivors still fail the run
    end
  end
end
