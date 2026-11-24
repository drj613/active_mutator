require "fileutils"
require "json"
require "set"

module ActiveMutator
  class KillerMemory
    def initialize(root)
      @root = root
      @path = File.join(root, ".active_mutator", "killers.json")
      @entries = load_entries
      @learned = {}
    end

    def group_for(item)
      id = ExampleId.normalize(@entries[key(item.mutation.subject)])
      return unless id && item.example_ids.any? { |candidate| ExampleId.normalize(candidate) == id }

      ExampleId.group_key(id)
    end

    def remember(item, killer)
      @learned[key(item.mutation.subject)] = killer.delete_prefix("#{@root}/")
    end

    def save(subjects: nil)
      return if @learned.empty? && (!subjects || @entries.empty?)

      keys = subjects&.map { |subject| key(subject) }&.to_set
      FileUtils.mkdir_p(File.dirname(@path))
      AtomicFile.write(@path) do
        entries = load_entries.merge(@learned)
        entries.select! { |key, _| keys.include?(key) } if keys
        JSON.generate(entries)
      end
    rescue SystemCallError
      # A warm coverage map can be used from a read-only cache.
      nil
    end

    private

    def key(subject)
      JSON.generate([subject.file.delete_prefix("#{@root}/"), subject.name, subject.kind])
    end

    def load_entries
      data = JSON.parse(File.read(@path))
      data.is_a?(Hash) ? data : {}
    rescue SystemCallError, JSON::ParserError
      {}
    end
  end
end
