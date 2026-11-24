require "digest"
require "fileutils"
require "json"

module ActiveMutator
  class VerdictStore
    STATUSES = { "killed" => :killed, "survived" => :survived }.freeze
    SCHEMA = 1

    def initialize(config, map)
      @root = config.root
      @path = File.join(@root, ".active_mutator", "verdicts.json")
      @digests = {}
      spec_paths = config.spec_paths.map { |path| File.expand_path(path, @root) + "/" }
      spec_digests = map.digests.select do |file, _|
        spec_paths.any? { |path| File.expand_path(file, @root).start_with?(path) }
      end
      shared = spec_digests.reject { |file, _| file.end_with?("_spec.rb") }
      inputs = [".rspec", "Gemfile", "Gemfile.lock", *config.operators, *config.requires, config.preload_helper]
      inputs.concat(Dir.glob("config/**/*", base: @root).sort)
      inputs.grep(String).each { |file| shared[file] = digest(file) }
      @context = fingerprint([SCHEMA, VERSION, RUBY_DESCRIPTION, config.operators,
                              Operators::Base::REGISTRY.map(&:name), config.requires, config.preload_helper,
                              config.spec_paths, config.class_level_closure_cap, shared.sort])
      @class_body_context = fingerprint([map.records.keys.sort, spec_digests.sort])
      @entries = read_entries
      @keys = {}
    end

    def partition(items)
      pending = []
      carried = []
      items.each do |item|
        mutation = item.mutation
        key = @keys[mutation] = key_for(item)
        entry = @entries[key]
        if valid_entry?(entry)
          carried << Result.new(mutation: mutation, status: STATUSES.fetch(entry["status"]),
                                details: entry["details"], killed_by: entry["killed_by"],
                                passed: entry["passed"], ignored: entry["ignored"], carried: true)
        else
          pending << item
        end
      end
      [pending, carried]
    end

    def discard(mutation)
      @keys.delete(mutation)
    end

    def save(results)
      entries = results.each_with_object({}) do |result, saved|
        key = @keys[result.mutation]
        next unless key && STATUSES.value?(result.status)

        saved[key] = { status: result.status, details: result.details, killed_by: result.killed_by,
                       passed: result.passed, ignored: result.ignored }
      end
      FileUtils.mkdir_p(File.dirname(@path))
      AtomicFile.write(@path, JSON.generate(context: @context, entries: entries))
    end

    private

    def key_for(item)
      mutation = item.mutation
      subject = mutation.subject
      file = subject.file.delete_prefix("#{@root}/")
      edit = mutation.edit
      specs = item.example_ids.map { |id| BaselineDelta.spec_file_of(id) }.uniq.sort
      source_digest = digest(file)
      spec_digests = specs.map { |spec| [spec, digest(spec)] }
      return unless source_digest && spec_digests.all? { |_, value| value }

      fingerprint([file, source_digest, subject.name, subject.kind, subject.byte_range.begin,
                   edit.range.begin, edit.range.end, edit.replacement, edit.operator,
                   item.example_ids.sort, spec_digests,
                   subject.class_body? ? @class_body_context : nil])
    end

    def digest(path)
      @digests.fetch(path) do
        absolute = File.expand_path(path, @root)
        @digests[path] = File.file?(absolute) ? Digest::SHA256.file(absolute).hexdigest : nil
      end
    end

    def fingerprint(value) = Digest::SHA256.hexdigest(JSON.generate(value))

    def read_entries
      data = JSON.parse(File.read(@path))
      return {} unless data.is_a?(Hash) && data["context"] == @context && data["entries"].is_a?(Hash)

      data["entries"]
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    def valid_entry?(entry)
      entry.is_a?(Hash) && STATUSES.key?(entry["status"]) &&
        entry["killed_by"].is_a?(Array) && entry["killed_by"].all?(String) &&
        entry["passed"].is_a?(Hash) && entry["passed"].values.all?(String) &&
        entry["ignored"].is_a?(Array) && entry["ignored"].all?(String)
    end
  end
end
