require "json"

# Parses bench/targets.json and expands each target's flag matrix into cells.
# Pure stdlib; never required by the gem's runtime.
module Bench
  class Plan
    Cell = Data.define(:id, :target_name, :type, :path, :git_url, :git_sha, :argv)

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def initialize(data)
      @targets = data.fetch("targets")
      @targets.each do |target|
        type = target.fetch("type")
        raise ArgumentError, "unknown target type: #{type}" unless %w[path git].include?(type)
      end
    end

    def cells
      @targets.flat_map { |t| expand(t) }
    end

    private

    def expand(target)
      type = target.fetch("type")
      path = type == "git" ? File.join("bench/.cache", target.fetch("name")) : target.fetch("path")
      combos(target.fetch("matrix", {})).map do |combo|
        Cell.new(
          id: cell_id(target.fetch("name"), combo),
          target_name: target.fetch("name"),
          type: type,
          path: path,
          git_url: target["url"],
          git_sha: target["sha"],
          argv: target.fetch("paths", []) + flag_argv(combo) +
                adaptive_default(combo) + ["--format", "stryker-json"]
        )
      end
    end

    # {"jobs"=>[1,2], "timeout_factor"=>[8.0]} -> [{"jobs"=>1,...}, {"jobs"=>2,...}]
    def combos(matrix)
      matrix.reduce([{}]) do |acc, (flag, values)|
        acc.flat_map { |combo| values.map { |v| combo.merge(flag => v) } }
      end
    end

    def cell_id(name, combo)
      return "#{name}-default" if combo.empty?

      suffix = combo.map { |flag, v| "#{abbrev(flag)}#{v}" }.join("-")
      "#{name}-#{suffix}"
    end

    def abbrev(flag)
      { "jobs" => "jobs", "timeout_factor" => "tf", "timeout_floor" => "floor" }
        .fetch(flag, flag.delete("_"))
    end

    # Deterministic by default: adaptive budgets are load-dependent and would
    # make the bench-diff regression gate flaky. Matrix rows may override.
    def adaptive_default(combo)
      combo.key?("adaptive_timeout") ? [] : ["--no-adaptive-timeout"]
    end

    def flag_argv(combo)
      combo.flat_map do |flag, v|
        name = flag.tr("_", "-")
        case v
        when true  then ["--#{name}"]
        when false then ["--no-#{name}"]
        else ["--#{name}", v.to_s]
        end
      end
    end
  end
end
