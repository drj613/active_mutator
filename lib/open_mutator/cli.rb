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
        requires: [], timeout_factor: 8.0, timeout_floor: 10.0, force_baseline: false
      }
      paths = OptionParser.new do |o|
        o.banner = "Usage: open_mutator [paths] [options]"
        o.on("--since REF", "Mutate only methods changed since git REF") { |v| options[:since] = v }
        o.on("--subject NAME", "Mutate only the named subject, e.g. Foo::Bar#baz") { |v| options[:subject_filter] = v }
        o.on("--jobs N", Integer, "Concurrent workers (default: half the CPU count)") { |v| options[:jobs] = v }
        o.on("--format FMT", %w[terminal json], "Output format") { |v| options[:format] = v.to_sym }
        o.on("--require FILE", "File to require before mutating (repeatable)") { |v| options[:requires] << v }
        o.on("--force-baseline", "Ignore cached coverage map") { options[:force_baseline] = true }
        o.on("--timeout-factor F", Float, "Timeout = baseline time * F + floor") { |v| options[:timeout_factor] = v }
        o.on("--timeout-floor S", Float, "Minimum timeout seconds") { |v| options[:timeout_floor] = v }
      end.parse(argv)

      Config.new(paths: paths, root: Dir.pwd, **options)
    end
  end
end
