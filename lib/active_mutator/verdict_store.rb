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
      @context = fingerprint([inputs.setup(status_file: map.status_file), Operators::Base::REGISTRY.filter_map(&:name)])
      @records = map.records
      @digests = map.digests
      @dependencies = {}
      @class_body_context = fingerprint([@records.keys.sort, @digests.sort, @spec_digests.sort])
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
      by_mutation = {}.compare_by_identity
      results.each { |result| by_mutation[result.mutation] = result }
      updates = @keys.to_h do |mutation, (key, signature)|
        result = by_mutation.fetch(mutation)
        entry = if signature && !@inconclusive[mutation] && STATUSES.value?(result.status)
                  { signature: signature, status: result.status, details: result.details,
                    killed_by: result.killed_by, passed: result.passed, ignored: result.ignored }
                end
        [key, entry]
      end
      FileUtils.mkdir_p(File.dirname(@path))
      AtomicFile.write(@path) do
        entries = prune ? {} : read_entries
        updates.each { |key, entry| entry ? entries[key] = entry : entries.delete(key) }
        JSON.generate(schema: SCHEMA, context: @context, entries: entries)
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
      ids = item.example_ids.sort
      dependencies = ids.map { |id| @dependencies[id] ||= dependency_fingerprint(id) }
      [key, fingerprint([source_digest, ids, spec_digests, scope, dependencies])]
    end

    def dependency_fingerprint(id)
      files = @records.fetch(id, []).map do |file, _|
        file.delete_prefix("#{@root}/")
      end.uniq.sort
      fingerprint(@digests.slice(*files))
    end

    def fingerprint(value) = Digest::SHA256.hexdigest(JSON.generate(value))

    def read_entries
      data = JSON.parse(File.read(@path))
      return {} unless data.is_a?(Hash) && data["schema"] == SCHEMA &&
                       data["context"] == @context && data["entries"].is_a?(Hash)

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
