require "fileutils"
require "json"

module ActiveMutator
  class KillerMemory
    def initialize(root)
      @root = root
      @path = File.join(root, ".active_mutator", "killers.json")
      @entries = load_entries
    end

    def group_for(item)
      id = ExampleId.normalize(@entries[key(item)])
      return unless id && item.example_ids.any? { |candidate| ExampleId.normalize(candidate) == id }

      ExampleId.group_key(id)
    end

    def remember(item, killer)
      @dirty = true
      @entries[key(item)] = killer.delete_prefix("#{@root}/")
    end

    def save
      return unless @dirty


      FileUtils.mkdir_p(File.dirname(@path))
      AtomicFile.write(@path, JSON.generate(@entries))
    end

    private

    def key(item)
      subject = item.mutation.subject
      JSON.generate([subject.file.delete_prefix("#{@root}/"), subject.name, subject.kind])
    end

    def load_entries
      data = JSON.parse(File.read(@path))
      data.is_a?(Hash) ? data : {}
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
  end
end
