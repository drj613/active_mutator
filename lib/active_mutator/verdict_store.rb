require "digest"
require "fileutils"
require "json"

module ActiveMutator
  class VerdictStore
    STATUSES = { "killed" => :killed, "survived" => :survived }.freeze
    SCHEMA = 2

    def initialize(config, map, inputs:)
      @root = config.root
      @path = File.join(@root, ".active_mutator", "verdicts.json")
      @source_digests = inputs.source_digests
      @spec_digests = inputs.spec_digests(map)
      @context = fingerprint([SCHEMA, inputs.setup, Operators::Base::REGISTRY.map(&:name)])
      @class_body_context = fingerprint([map.records.keys.sort, @spec_digests.sort])
      @entries = read_entries
      @keys = {}.compare_by_identity
      @inconclusive = {}.compare_by_identity
    end

    def partition(items)
      pending = []
      carried = []
      items.each do |item|
        mutation = item.mutation
        key, signature = identity_and_signature(item)
        @keys[mutation] = [key, signature]
        entry = @entries[key]
        if signature && valid_entry?(entry, signature)
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
      @inconclusive[mutation] = true
    end

    def save(results, prune:)
      updates = results.each_with_object({}) do |result, saved|
        key, signature = @keys[result.mutation]
        next unless key

        saved[key] = if signature && !@inconclusive[result.mutation] && STATUSES.value?(result.status)
                       { signature: signature, status: result.status, details: result.details,
                         killed_by: result.killed_by, passed: result.passed, ignored: result.ignored }
                     end
      end
      FileUtils.mkdir_p(File.dirname(@path))
      AtomicFile.write(@path) do
        entries = prune ? {} : read_entries
        updates.each { |key, entry| entry ? entries[key] = entry : entries.delete(key) }
        JSON.generate(context: @context, entries: entries)
      end
    rescue SystemCallError
      nil
    end

    private

    def identity_and_signature(item)
      mutation = item.mutation
      subject = mutation.subject
      file = subject.file.delete_prefix("#{@root}/")
      edit = mutation.edit
      key = fingerprint([file, subject.name, subject.kind, subject.byte_range.begin,
                         edit.range.begin, edit.range.end, edit.replacement, edit.operator])
      specs = item.example_ids.map { |id| BaselineDelta.spec_file_of(id).delete_prefix("#{@root}/") }.uniq.sort
      source_digest = @source_digests[subject.file]
      spec_digests = @spec_digests.values_at(*specs)
      return [key, nil] unless source_digest && spec_digests.all?

      scope = @class_body_context if subject.class_body?
      [key, fingerprint([source_digest, item.example_ids.sort, spec_digests, scope])]
    end

    def fingerprint(value) = Digest::SHA256.hexdigest(JSON.generate(value))

    def read_entries
      data = JSON.parse(File.read(@path))
      return {} unless data.is_a?(Hash) && data["context"] == @context && data["entries"].is_a?(Hash)

      data["entries"]
    rescue SystemCallError, JSON::ParserError
      {}
    end

    def valid_entry?(entry, signature)
      entry.is_a?(Hash) && entry["signature"] == signature && STATUSES.key?(entry["status"]) &&
        entry["killed_by"].is_a?(Array) && entry["killed_by"].all?(String) &&
        entry["passed"].is_a?(Hash) && entry["passed"].values.all?(String) &&
        entry["ignored"].is_a?(Array) && entry["ignored"].all?(String)
    end
  end
end
