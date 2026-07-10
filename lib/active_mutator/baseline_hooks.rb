# Loaded standalone via RUBYOPT=-ractive_mutator/baseline_hooks in the host
# project's suite, before rspec boots, so Coverage instruments everything
# the suite loads (including code loaded by spec_helper). Records per-example
# coverage diffs and writes the inverted map to ACTIVE_MUTATOR_BASELINE_OUT.
require "json"

module ActiveMutator
  module BaselineHooks
    RECORDS = {}
    TIMES = {}

    def self.diff_coverage(before, after, root)
      hits = []
      after.each do |path, data|
        next unless path.start_with?(root)

        # Relative to root, not a global substring check: `root` itself may
        # contain "/spec/" (e.g. a fixture nested under this gem's own
        # spec/fixtures/ tree), which would otherwise falsely exclude every
        # file under it.
        relative = path.delete_prefix(root)
        next if relative.start_with?("/spec/")

        before_lines = before.dig(path, :lines)
        data[:lines].each_with_index do |count, idx|
          next if count.nil?

          previous = before_lines ? before_lines[idx].to_i : 0
          hits << [path, idx + 1] if count > previous
        end
      end
      hits
    end

    def self.build_payload(records, times)
      { "version" => 2, "records" => records, "times" => times }
    end
  end
end

if ENV["ACTIVE_MUTATOR_BASELINE_OUT"]
  require "coverage"
  Coverage.start(lines: true)
  require "rspec/core" # loaded via RUBYOPT, so rspec isn't up yet

  RSpec.configure do |config|
    config.around(:each) do |example|
      before = Coverage.peek_result
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      example.run
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      after = Coverage.peek_result
      root = ENV.fetch("ACTIVE_MUTATOR_ROOT")
      ActiveMutator::BaselineHooks::RECORDS[example.id] =
        ActiveMutator::BaselineHooks.diff_coverage(before, after, root)
      # NOT example.execution_result.run_time: that is nil until after
      # around hooks complete.
      ActiveMutator::BaselineHooks::TIMES[example.id] = elapsed
    end

    config.after(:suite) do
      payload = ActiveMutator::BaselineHooks.build_payload(
        ActiveMutator::BaselineHooks::RECORDS, ActiveMutator::BaselineHooks::TIMES
      )
      File.write(ENV.fetch("ACTIVE_MUTATOR_BASELINE_OUT"), JSON.generate(payload))
    end
  end
end
