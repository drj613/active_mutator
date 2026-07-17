require "json"
require "tmpdir"
require_relative "../../bench/lib/bench/plan"
require_relative "../../bench/lib/bench/runner"

RSpec.describe Bench::Runner do
  def cell(id: "tiny-jobs1", argv: ["lib", "--jobs", "1", "--format", "stryker-json"])
    Bench::Plan::Cell.new(id: id, target_name: "tiny", type: "path",
                          path: "spec/fixtures/tiny_project",
                          git_url: nil, git_sha: nil, argv: argv)
  end

  def fake_exec(log, statuses: Hash.new(true))
    lambda do |argv, chdir:|
      log << { argv: argv, chdir: chdir }
      statuses[argv.join(" ")]
    end
  end

  it "runs baseline stage then mutation stage per cell and writes bench.json" do
    Dir.mktmpdir do |out|
      log = []
      runner = described_class.new(cells: [cell], repo_root: Dir.pwd,
                                   out_dir: out, exec: fake_exec(log))
      # Stub the report copy: the fake exec produces no mutation-report.json.
      allow(runner).to receive(:collect_report)
      runner.call

      mutator_calls = log.select { |c| c[:argv].any? { |a| a.end_with?("active_mutator") } }
      expect(mutator_calls.size).to eq(2)
      expect(mutator_calls[0][:argv]).to include("--force-baseline", "--max-mutants", "0")
      expect(mutator_calls[1][:argv]).to include("--jobs", "1")
      expect(mutator_calls).to all(include(chdir: end_with("spec/fixtures/tiny_project")))

      summary = JSON.parse(File.read(File.join(out, "tiny-jobs1", "bench.json")))
      expect(summary.keys).to include("cell", "baseline_seconds", "mutation_seconds", "exit_ok")
      expect(summary["cell"]).to eq("tiny-jobs1")
      expect(summary["exit_ok"]).to be(true)
    end
  end

  it "bundle-installs each target once, not per cell" do
    Dir.mktmpdir do |out|
      log = []
      runner = described_class.new(cells: [cell(id: "a"), cell(id: "b")],
                                   repo_root: Dir.pwd, out_dir: out, exec: fake_exec(log))
      allow(runner).to receive(:collect_report)
      runner.call
      installs = log.count { |c| c[:argv][0, 2] == %w[bundle install] }
      expect(installs).to eq(1)
    end
  end

  it "records a failed mutation stage as exit_ok false and keeps going" do
    Dir.mktmpdir do |out|
      log = []
      statuses = Hash.new(true)
      bad = cell(id: "bad", argv: ["lib", "--jobs", "1", "--format", "stryker-json"])
      exec = lambda do |argv, chdir:|
        log << { argv: argv, chdir: chdir }
        # Fail only the bad cell's real mutation stage (no --force-baseline in argv).
        !(argv.any? { |a| a.end_with?("active_mutator") } &&
          !argv.include?("--force-baseline") && argv.include?("1"))
      end
      runner = described_class.new(cells: [bad, cell(id: "good", argv: ["lib", "--jobs", "2", "--format", "stryker-json"])],
                                   repo_root: Dir.pwd, out_dir: out, exec: exec)
      allow(runner).to receive(:collect_report)
      runner.call
      bad_summary = JSON.parse(File.read(File.join(out, "bad", "bench.json")))
      good_summary = JSON.parse(File.read(File.join(out, "good", "bench.json")))
      expect(bad_summary["exit_ok"]).to be(false)
      expect(good_summary["exit_ok"]).to be(true)
    end
  end
end
