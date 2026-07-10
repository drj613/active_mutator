require "optparse"

module OpenMutator
  module CLI
    def self.run(argv)
      Runner.new(parse(argv)).call
    rescue OptionParser::ParseError, Error => e
      warn "open_mutator: #{e.message}"
      2
    end

    def self.parse(argv)
      options = {
        # Half the cores, not all of them: each worker pays full RSpec setup,
        # and system-spec workers boot a browser + app server. Full-core
        # oversubscription starves workers of CPU and turns slow-but-honest
        # kills into false timeouts (observed on a real Rails monolith).
        since: nil, subject_filter: nil, jobs: [Etc.nprocessors / 2, 1].max,
        format: :terminal,
        # Budgets derive from baseline times measured warm and unloaded; the
        # factor must absorb parallel-load slowdown, and the floor the fork's
        # boot cost (RSpec setup + spec file loading).
        requires: [], timeout_factor: 8.0, timeout_floor: 10.0, force_baseline: false,
        preload_helper: nil, serial_patterns: ["spec/system/", "spec/features/"],
        browser_boot_seconds: 15.0, accept_survivors: false
      }
      paths = OptionParser.new do |o|
        o.banner = "Usage: open_mutator [paths] [options]"
        o.on("--since REF", "Mutate only methods changed since git REF") { |v| options[:since] = v }
        o.on("--changed", "Mutate uncommitted work (alias for --since HEAD, plus untracked files)") { options[:since] = "HEAD" }
        o.on("--subject NAME", "Mutate only the named subject, e.g. Foo::Bar#baz") { |v| options[:subject_filter] = v }
        o.on("--jobs N", Integer, "Concurrent workers (default: half the CPU count)") { |v| options[:jobs] = v }
        o.on("--format FMT", %w[terminal json], "Output format") { |v| options[:format] = v.to_sym }
        o.on("--require FILE", "File to require before mutating (repeatable)") { |v| options[:requires] << v }
        o.on("--force-baseline", "Ignore cached coverage map") { options[:force_baseline] = true }
        o.on("--timeout-factor F", Float, "Timeout = baseline time * F + floor") { |v| options[:timeout_factor] = v }
        o.on("--timeout-floor S", Float, "Minimum timeout seconds") { |v| options[:timeout_floor] = v }
        o.on("--preload-helper FILE", "Spec helper to preload in the parent (default: auto-detect)") { |v| options[:preload_helper] = v }
        o.on("--no-preload-helper", "Skip spec-helper preload") { options[:preload_helper] = :none }
        o.on("--serial-pattern PAT", "Covering-path prefix that forces the serial lane (repeatable; replaces defaults on first use)") do |v|
          options[:serial_patterns] = [] unless options[:serial_patterns_replaced]
          options[:serial_patterns_replaced] = true
          options[:serial_patterns] << v
        end
        o.on("--browser-boot-seconds S", Float, "Extra timeout budget for serial-lane mutants") { |v| options[:browser_boot_seconds] = v }
        o.on("--accept-survivors", "Record surviving mutants into the acceptance ledger") { options[:accept_survivors] = true }
      end.parse(argv)
      options.delete(:serial_patterns_replaced)

      Config.new(paths: paths, root: Dir.pwd, **options)
    end
  end
end
