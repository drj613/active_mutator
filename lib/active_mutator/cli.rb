require "optparse"

module ActiveMutator
  module CLI
    def self.run(argv)
      Runner.new(parse(argv)).call
    rescue OptionParser::ParseError, Error => e
      warn "active_mutator: #{e.message}"
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
        browser_boot_seconds: 15.0, accept_survivors: false, exclude: [],
        max_mutants: nil, debug_plan: false, fail_at: nil, adaptive_timeout: true,
        operators: [], class_level: true, class_level_closure_cap: 10
      }
      options.merge!(ConfigFile.load(Dir.pwd))
      paths = OptionParser.new do |o|
        o.banner = "Usage: active_mutator [paths] [options]"
        o.on("--since REF", "Mutate only methods changed since git REF") { |v| options[:since] = v }
        o.on("--changed", "Mutate uncommitted work (alias for --since HEAD, plus untracked files)") { options[:since] = "HEAD" }
        o.on("--subject NAME", "Mutate matching subjects: Foo::Bar#baz, Foo::Bar, Foo::Bar*, Foo::Bar#*") { |v| options[:subject_filter] = v }
        o.on("--jobs N", Integer, "Concurrent workers (default: half the CPU count)") { |v| options[:jobs] = v }
        o.on("--format FMT", ConfigFile::FORMATS, "Output format") { |v| options[:format] = v.tr("-", "_").to_sym }
        o.on("--require FILE", "File to require before mutating (repeatable; adds to config-file requires)") { |v| options[:requires] << v }
        o.on("--operator FILE", "Ruby file defining a custom operator, loaded before analysis (repeatable)") { |v| options[:operators] << v }
        o.on("--[no-]class-level", "Mutate class-level code: macros, constants, DSL lambdas (default: on)") { |v| options[:class_level] = v }
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
        o.on("--[no-]adaptive-timeout", "Scale timeout budgets from observed worker wall times (default: on)") { |v| options[:adaptive_timeout] = v }
        o.on("--accept-survivors", "Record surviving mutants into the acceptance ledger") { options[:accept_survivors] = true }
        o.on("--exclude PAT", "Skip files matching glob, relative to root (repeatable)") { |v| options[:exclude] << v }
        o.on("--max-mutants N", Integer, "Deterministically sample the first N mutants") { |v| options[:max_mutants] = v }
        o.on("--debug-plan", "Print the planned mutant list as JSON and exit") { options[:debug_plan] = true }
        o.on("--fail-at SCORE", Float, "Exit 0 if mutation score >= SCORE even with survivors (default: any survivor fails)") do |v|
          raise OptionParser::InvalidArgument, "--fail-at must be within 0..100" unless (0..100).cover?(v)
          options[:fail_at] = v
        end
      end.parse(argv)
      options.delete(:serial_patterns_replaced)

      Config.new(paths: paths, root: Dir.pwd, **options)
    end
  end
end
