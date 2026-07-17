require "fileutils"
require "json"

# Executes plan cells against fixture/pinned targets. Pure stdlib;
# never required by the gem's runtime.
module Bench
  class Runner
    def initialize(cells:, repo_root:, out_dir:, exec: nil, clock: nil)
      @cells = cells
      @repo_root = repo_root
      @out_dir = out_dir
      @exec = exec || method(:system_exec)
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @prepared = {}
    end

    def call
      @cells.each do |cell|
        target_dir = prepare_target(cell)
        run_cell(cell, target_dir)
      end
    end

    private

    def prepare_target(cell)
      dir = File.expand_path(cell.path, @repo_root)
      return @prepared[cell.target_name] if @prepared.key?(cell.target_name)

      if cell.type == "git"
        unless Dir.exist?(dir)
          FileUtils.mkdir_p(File.dirname(dir))
          @exec.call(["git", "clone", cell.git_url, dir], chdir: @repo_root) ||
            raise("clone failed: #{cell.git_url}")
        end
        @exec.call(["git", "checkout", cell.git_sha], chdir: dir) ||
          raise("checkout failed: #{cell.git_sha}")
      end
      @exec.call(%w[bundle install], chdir: dir) || raise("bundle install failed in #{dir}")
      # Cold cache per target so the measured baseline stage is a real full run.
      FileUtils.rm_rf(File.join(dir, ".active_mutator"))
      @prepared[cell.target_name] = dir
    end

    def run_cell(cell, target_dir)
      cell_dir = File.join(@out_dir, cell.id)
      FileUtils.mkdir_p(cell_dir)
      mutator = File.expand_path("exe/active_mutator", @repo_root)

      baseline_seconds, baseline_ok = timed do
        @exec.call(["bundle", "exec", mutator, *cell.argv, "--force-baseline", "--max-mutants", "0"],
                   chdir: target_dir)
      end
      mutation_seconds, ok = timed do
        @exec.call(["bundle", "exec", mutator, *cell.argv], chdir: target_dir)
      end
      collect_report(target_dir, cell_dir)

      File.write(File.join(cell_dir, "bench.json"), JSON.pretty_generate(
        "cell" => cell.id, "target" => cell.target_name, "argv" => cell.argv,
        "baseline_seconds" => baseline_seconds.round(2),
        "baseline_ok" => !!baseline_ok,
        "mutation_seconds" => mutation_seconds.round(2),
        "exit_ok" => !!ok
      ))
    end

    def timed
      started = @clock.call
      result = yield
      [@clock.call - started, result]
    end

    def collect_report(target_dir, cell_dir)
      report = File.join(target_dir, ".active_mutator", "mutation-report.json")
      FileUtils.cp(report, File.join(cell_dir, "mutation-report.json")) if File.exist?(report)
    end

    def system_exec(argv, chdir:)
      log = File.join(@out_dir, "exec.log")
      File.open(log, "a") { |f| f.puts("$ (cd #{chdir}) #{argv.join(" ")}") }
      # BUNDLE_GEMFILE pinned to the target so `bundle exec` resolves the
      # target's bundle (which vendors active_mutator by path), not ours.
      system({ "BUNDLE_GEMFILE" => File.join(chdir, "Gemfile") },
             *argv, chdir: chdir, out: [log, "a"], err: [log, "a"])
    end
  end
end
