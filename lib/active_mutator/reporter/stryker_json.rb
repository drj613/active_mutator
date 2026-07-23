require "json"

module ActiveMutator
  module Reporter
    # mutation-testing-report-schema v2 (the Stryker ecosystem format).
    # Load the written file in https://microsoft.github.io/mutation-testing-elements/
    # for the interactive per-file mutant viewer.
    #
    # Schema constraints honored here: 1-based positive line/column, integer
    # thresholds, tool-specific data only under config.active_mutator.
    # Invalid mutants are discarded before results exist, so they appear as a
    # count in the extras, never as CompileError mutants.
    class StrykerJson
      SCHEMA_URL = "https://git.io/mutation-testing-schema"
      STATUS = { killed: "Killed", survived: "Survived", timeout: "Timeout",
                 error: "RuntimeError", uncovered: "NoCoverage", accepted: "Ignored",
                 skipped: "Ignored" }.freeze
      ACCEPTED_REASON = "Accepted as equivalent in #{AcceptedLedger::FILENAME}".freeze
      REPORT_PATH = File.join(".active_mutator", "mutation-report.json")

      # Injected by Runner once the baseline map exists; nil in unit tests.
      attr_writer :coverage_map

      def initialize(root:, out: $stdout)
        @root = root
        @out = out
        @coverage_map = nil
      end

      def on_result(result)
        @out.print(Terminal::CHARS.fetch(result.status))
      end

      def summary(results, invalid_count:)
        report = build_report(results, invalid_count)
        path = File.join(@root, REPORT_PATH)
        AtomicFile.write(path, JSON.pretty_generate(report))
        @out.puts "", "", "Stryker report written to #{REPORT_PATH}"
      end

      private

      def build_report(results, invalid_count)
        mutants_by_file = results.group_by { |r| r.mutation.subject.file }
        report = {
          "$schema" => SCHEMA_URL,
          "schemaVersion" => "2",
          "thresholds" => { "high" => 80, "low" => 60 },
          "projectRoot" => @root,
          "config" => { "active_mutator" => { "invalid_discarded" => invalid_count,
                                              "version" => VERSION } },
          "files" => mutants_by_file.to_h { |file, rs| [relative(file), file_entry(file, rs)] }
        }
        tests = referenced_examples(results)
        report["testFiles"] = test_files(tests) unless tests.empty?
        report
      end

      def file_entry(file, results)
        source = File.read(file)
        { "language" => "ruby", "source" => source,
          "mutants" => results.map { |r| mutant(r, source) } }
      end

      def mutant(result, source)
        loc = SourceLocation.locate(source, result.mutation.edit.range)
        entry = {
          "id" => next_id,
          "mutatorName" => result.mutation.edit.operator,
          "location" => { "start" => stringify(loc[:start]), "end" => stringify(loc[:end]) },
          "status" => STATUS.fetch(result.status),
          "replacement" => result.mutation.edit.replacement,
          "description" => result.mutation.description
        }
        reason = status_reason(result)
        entry["statusReason"] = reason if reason
        covered = covered_by(result)
        entry["coveredBy"] = covered if covered
        entry
      end

      def status_reason(result)
        return ACCEPTED_REASON if result.status == :accepted

        result.details&.to_s
      end

      def covered_by(result)
        return nil unless @coverage_map

        subject = result.mutation.subject
        # Class-body lines execute at load time, so per-line coverage never
        # attributes examples to them (see Runner#examples_for_mutation). Mirror
        # the scheduling substitution — every example that loaded the file — so
        # the viewer shows real test linkage instead of an empty coveredBy.
        if subject.class_body?
          examples = @coverage_map.examples_covering_file(subject.file)
          return examples.empty? ? nil : examples.sort
        end

        @coverage_map.examples_for(subject.file, result.mutation.lines)
      end

      def referenced_examples(results)
        results.flat_map { |r| covered_by(r) || [] }.uniq.sort
      end

      # Group example ids by spec path (the id up to the trailing "[...]")
      # so the viewer's test panel resolves coveredBy references.
      def test_files(example_ids)
        example_ids
          .group_by { |id| id.sub(%r{\A\./}, "").sub(/\[.*\]\z/, "") }
          .transform_values do |ids|
            { "tests" => ids.map { |id| { "id" => id, "name" => id } } }
          end
      end

      def next_id
        @next_id = (@next_id || -1) + 1
        @next_id.to_s
      end

      def stringify(position) = { "line" => position[:line], "column" => position[:column] }

      def relative(file) = file.delete_prefix(@root.chomp("/") + "/")
    end
  end
end
