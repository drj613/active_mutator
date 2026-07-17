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

    # If a changed constant is referenced by more than this share of all spec
    # files, a full re-run is cheaper and simpler than a giant partial one.
    REFERENCE_FULL_RATIO = 0.5

    def self.compute(old_digests:, new_digests:, coverage_map:, root:)
      changed = (old_digests.keys | new_digests.keys)
                .reject { |k| old_digests[k] == new_digests[k] }
      return FULL if changed.any? { |k| full_trigger?(k) }

      rerun_spec_files = []
      rerun_example_ids = []
      drop_example_ids = []
      drop_source_files = []

      # Read the spec-file list and their contents once per compute call, not
      # once per changed source file: newly_covering_candidates scans every
      # spec file, so re-globbing and re-reading inside the loop was
      # O(changed_files x spec_files) IO. Built lazily so a delta with no
      # scannable source change pays nothing.
      spec_contents = nil

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
          unless added
            rerun_example_ids.concat(coverage_map.examples_covering_file(abs))
          end
          unless deleted
            spec_contents ||= Dir[File.join(root, "spec/**/*_spec.rb")].to_h { |f| [f, File.read(f)] }
            candidates = newly_covering_candidates(root: root, rel: rel, coverage_map: coverage_map,
                                                   spec_contents: spec_contents)
            return FULL if candidates == :full

            rerun_spec_files.concat(candidates)
          end
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

    # #11: an unchanged spec file can START covering a changed source file
    # because of the edit itself. Cheap static detection: spec files that
    # textually reference a constant the changed file defines, but currently
    # contribute zero coverage to it, get re-run. Files already covering it
    # are handled example-by-example via rerun_example_ids.
    def self.newly_covering_candidates(root:, rel:, coverage_map:, spec_contents:)
      abs = File.join(root, rel)
      return [] unless File.exist?(abs)

      constants = DefinedConstants.in_source(File.read(abs))
      return [] if constants.empty?

      all_specs = spec_contents.keys

      covering_specs = coverage_map.examples_covering_file(abs)
                                   .map { |id| spec_file_of(id) }.to_a.uniq
      # Escaping is required: dynamic-namespace class definitions (e.g.
      # `class (a)::Baz`, `class foo.bar::Baz`) make constant_path.slice carry
      # regex metachars. Unescaped, "(a)::Baz" would match the literal text
      # "a::Baz" — a false candidate.
      # TODO(#11, Task 10 residual gap): a top-level `class ::Foo` yields the
      # slice "::Foo", and /\b::Foo\b/ can never match (no word boundary
      # before ":"), so such files are silently unscanned.
      pattern = /\b(?:#{constants.map { |c| Regexp.escape(c) }.join("|")})\b/
      candidates = all_specs.filter_map do |spec_abs|
        spec_rel = spec_abs.delete_prefix(root).delete_prefix("/")
        next if covering_specs.include?(spec_rel)

        spec_rel if spec_contents.fetch(spec_abs).match?(pattern)
      end
      if candidates.size > 1 && candidates.size > all_specs.size * REFERENCE_FULL_RATIO
        # Never silently degrade: a full baseline where the user expected an
        # incremental refresh must be explained, or it looks like a hang.
        warn "active_mutator: constant-reference scan matched #{candidates.size} of " \
             "#{all_specs.size} spec files for #{rel}; falling back to full baseline"
        return :full
      end

      candidates
    end

    def self.spec_file_of(example_id)
      example_id.sub(%r{\A\./}, "").sub(/\[.*\]\z/, "")
    end
  end
end
