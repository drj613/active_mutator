require "json"

module OpenMutator
  class CoverageMap
    def self.load(path) = new(JSON.parse(File.read(path)))

    def initialize(data)
      @map = data.fetch("map")
      @times = data.fetch("times", {})
      @digests = data.fetch("digests", {})
    end

    def examples_for(file, lines)
      lines.flat_map { |line| @map.fetch("#{file}:#{line}", []) }.uniq.sort
    end

    def time_for(example_ids)
      # `|| 0.0`, not fetch-with-default: a key present with nil value must
      # also coerce to zero, or Runner#plan_work explodes with TypeError.
      example_ids.sum { |id| @times[id] || 0.0 }
    end

    def fresh?(digests) = @digests == digests
  end
end
