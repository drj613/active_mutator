require "json"

module ActiveMutator
  # Cache format v2: primary data is per-example `records`
  # ({example_id => [[abs_path, line], ...]}); the inverted index is derived
  # in memory at load. A missing/old version is simply stale: the cache is
  # disposable, so there is no migration path, only regeneration.
  class CoverageMap
    def self.load(path) = new(JSON.parse(File.read(path)))

    attr_reader :version, :records

    def initialize(data)
      @version = data["version"]
      @records = data.fetch("records", {})
      @times = data.fetch("times", {})
      @digests = data.fetch("digests", {})
      @map = build_map
    end

    def examples_for(file, lines)
      lines.flat_map { |line| @map.fetch("#{file}:#{line}", []) }.uniq.sort
    end

    def time_for(example_ids)
      # `|| 0.0`, not fetch-with-default: a key present with nil value must
      # also coerce to zero, or Runner#plan_work explodes with TypeError.
      example_ids.sum { |id| @times[id] || 0.0 }
    end

    def fresh?(digests) = @version == 2 && @digests == digests

    def examples_covering_file(abs_path)
      @records.filter_map do |example_id, hits|
        example_id if hits.any? { |(path, _line)| path == abs_path }
      end
    end

    def examples_for_spec_file(rel_spec_path)
      @records.keys.select do |example_id|
        example_id.sub(%r{\A\./}, "").start_with?("#{rel_spec_path}[")
      end
    end

    private

    def build_map
      map = Hash.new { |h, k| h[k] = [] }
      @records.each do |example_id, hits|
        hits.each { |(path, line)| map["#{path}:#{line}"] << example_id }
      end
      map
    end
  end
end
