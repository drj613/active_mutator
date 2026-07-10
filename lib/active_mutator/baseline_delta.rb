module ActiveMutator
  # Decides how to refresh a stale coverage cache: surgically (re-run only
  # affected spec files / examples) or fully (the safe fallback). Rules per
  # the v1.1 spec's delta table; anything ambiguous prefers full.
  class BaselineDelta
    Delta = Data.define(:full, :rerun_spec_files, :rerun_example_ids,
                        :drop_example_ids, :drop_source_files) do
      def full? = full
    end

    FULL = Delta.new(full: true, rerun_spec_files: [], rerun_example_ids: [],
                     drop_example_ids: [], drop_source_files: [])

    def self.compute(old_digests:, new_digests:, coverage_map:, root:)
      changed = (old_digests.keys | new_digests.keys)
                .reject { |k| old_digests[k] == new_digests[k] }
      return FULL if changed.any? { |k| full_trigger?(k) }

      rerun_spec_files = []
      rerun_example_ids = []
      drop_example_ids = []
      drop_source_files = []

      changed.each do |rel|
        added = !old_digests.key?(rel)
        deleted = !new_digests.key?(rel)
        if rel.start_with?("spec/")
          owned = coverage_map.examples_for_spec_file(rel)
          if deleted
            # A deleted spec file with no records is support-like: other spec
            # files may require it, and partial re-runs would explode. Full.
            return FULL if owned.empty?
            drop_example_ids.concat(owned)
          elsif !added && owned.empty?
            return FULL # pre-existing spec file owning no examples: support-like
          else
            rerun_spec_files << rel
          end
        else
          abs = File.join(root, rel)
          drop_source_files << abs if deleted
          rerun_example_ids.concat(coverage_map.examples_covering_file(abs)) unless added
        end
      end

      Delta.new(full: false,
                rerun_spec_files: rerun_spec_files.uniq.sort,
                rerun_example_ids: rerun_example_ids.uniq.sort,
                drop_example_ids: drop_example_ids.uniq.sort,
                drop_source_files: drop_source_files.uniq.sort)
    end

    def self.full_trigger?(rel)
      rel.start_with?("spec/support/") || !rel.end_with?(".rb")
    end
  end
end
