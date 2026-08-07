require "json"

module ActiveMutator
  class Runner
    def initialize(config, reporter: nil)
      @config = config
      @reporter = reporter || build_reporter
    end

    def call
      ENV["ACTIVE_MUTATOR"] = "1"
      load_operators
      ClosureReload.cap = @config.class_level_closure_cap
      preload!
      preload_spec_helper!
      map = Baseline.new(root: @config.root, spec_paths: @config.spec_paths)
              .coverage_map(force: @config.force_baseline)
      @reporter.coverage_map = map if @reporter.respond_to?(:coverage_map=)
      subjects = discover_subjects
      analyses = subjects.map { |s| Engine.new.analyze(s) }
      mutations = analyses.flat_map(&:mutations)
      mutations = mutations.first(@config.max_mutants) if @config.max_mutants
      invalid_count = analyses.sum(&:invalid_count)

      fingerprints = Fingerprint.for_mutations(mutations, root: @config.root)
      ledger = AcceptedLedger.load(@config.root)
      scanned_files = prune_scope(subjects)
      warn_stale(ledger, fingerprints.values, scanned_files)

      items, pre_results, phase1_ids = plan_work(mutations, map, ledger: ledger, fingerprints: fingerprints)
      return debug_plan(items, pre_results) if @config.debug_plan

      pre_results.each { |r| @reporter.on_result(r) }
      calibrators = if @config.adaptive_timeout
                      { parallel: TimeoutCalibrator.new, serial: TimeoutCalibrator.new }
                    end
      scheduler = Scheduler.new(jobs: @config.jobs, on_result: @reporter.method(:on_result),
                                calibrators: calibrators)
      results = scheduler.run(items) + pre_results
      # Phase 2 runs on its own scheduler (built lazily inside), so pass nil.
      results = escalate_class_body_survivors(results, nil, map, phase1_ids: phase1_ids)

      accept_survivors!(ledger, results, fingerprints, scanned_files) if @config.accept_survivors

      @reporter.summary(results, invalid_count: invalid_count)
      exit_code(results)
    end

    # Returns [work_items, pre_results, phase1_ids]. phase1_ids maps each
    # planned mutation to the example ids it was scheduled against, so phase 2
    # escalation can subtract what was already run. Public for unit testing.
    def plan_work(mutations, map, ledger: nil, fingerprints: {})
      items = []
      pre_results = []
      mutations.each do |mutation|
        if ledger&.accepted?(fingerprints[mutation])
          pre_results << Result.new(mutation: mutation, status: :accepted, details: nil)
          next
        end
        example_ids = examples_for_mutation(mutation, map)
        if example_ids.empty?
          pre_results << Result.new(mutation: mutation, status: :uncovered, details: nil)
        else
          items << build_work_item(mutation, example_ids, map)
        end
      end
      phase1_ids = items.to_h { |i| [i.mutation, i.example_ids] }
      [items, pre_results, phase1_ids]
    end

    # Phase 2 of the class-body kill pipeline (public for unit testing).
    # A class-body survivor is only DECLARED after every spec file that
    # references the constant has had its shot: re-enqueue against the
    # referencing files phase 1 didn't run, and take the escalated verdict.
    #
    # `scheduler` is injectable for unit tests; in the normal run it is nil and
    # a dedicated escalation scheduler is built lazily (only when there is
    # phase-2 work) with NO on_result — escalation is a refinement pass, and
    # reporting through the live callback would print a second status char for a
    # mutant already streamed in phase 1. The final summary reflects the
    # escalated verdicts regardless.
    def escalate_class_body_survivors(results, scheduler, map, phase1_ids:)
      candidates = results.select { |r| r.status == :survived && r.mutation.subject.class_body? }
      # Perf gate: skip reading the whole spec suite into memory in the common
      # case of no class-body survivors. (Deleting this line is a behavioral
      # no-op — the later `items.empty?` return still guards correctness — so
      # its mutant is a known equivalent.)
      return results if candidates.empty?

      spec_contents = BaselineDelta.spec_file_contents(root: @config.root, spec_paths: @config.spec_paths)
      patterns = {} # subject file => constant-reference pattern (parsed once per file)
      items = {}
      candidates.each do |r|
        file = r.mutation.subject.file
        pattern = patterns.fetch(file) do
          patterns[file] = BaselineDelta.constant_reference_pattern(File.read(file))
        end
        next unless pattern

        ids = escalation_examples(map, spec_contents, phase1_ids.fetch(r.mutation, []), pattern)
        next if ids.empty?

        items[r.mutation] = build_work_item(r.mutation, ids, map)
      end
      return results if items.empty?

      scheduler ||= Scheduler.new(jobs: @config.jobs)
      escalated = scheduler.run(items.values).to_h { |res| [res.mutation, res] }
      results.map do |r|
        # A replacement only ever exists for a survived candidate (items is
        # built solely from those), so no redundant status re-check is needed.
        replacement = escalated[r.mutation]
        next r unless replacement

        case replacement.status
        when :killed
          replacement
        when :survived
          extra = items[r.mutation].example_ids.map { |id| BaselineDelta.spec_file_of(id) }.uniq.size
          replacement.with(details: "escalated (+#{extra} spec files)")
        else
          # A timeout/error/skip in phase 2 did NOT prove a kill — the mutant
          # already survived phase 1, so keep that verdict rather than letting
          # an inconclusive escalation inflate the score (a :timeout counts as
          # detected in exit_code/score).
          r
        end
      end
    end

    def exit_code(results)
      survived = results.count { |r| r.status == :survived }
      return 0 if survived.zero?
      return 1 unless @config.fail_at

      detected = results.count { |r| %i[killed timeout].include?(r.status) }
      score = detected * 100.0 / (detected + survived)
      score >= @config.fail_at ? 0 : 1
    end

    private

    # Single source of truth for lane/timeout/variable derivation, shared by
    # phase-1 planning and phase-2 escalation so the two never drift.
    def build_work_item(mutation, example_ids, map)
      lane = example_ids.any? { |id| serial_example?(id) } ? :serial : :parallel
      variable = map.time_for(example_ids) * @config.timeout_factor
      boot_extra = lane == :serial ? @config.browser_boot_seconds : 0.0
      timeout = variable + @config.timeout_floor + boot_extra
      WorkItem.new(mutation: mutation, example_ids: example_ids,
                   timeout: timeout, lane: lane, variable: variable)
    end

    # Spec files that textually match `pattern` (a constant-reference pattern
    # for the subject's file, built via BaselineDelta.constant_reference_pattern
    # so the escaping/word-boundary rules stay shared), minus everything phase 1
    # already ran; returned as example ids.
    #
    # Two deliberate choices: (a) matching is TEXTUAL, so a constant named in a
    # comment or string still counts — intentional, since the worst case is a
    # wasted run and the verdict stays correct; (b) unlike
    # BaselineDelta.newly_covering_candidates there is intentionally NO fan-out
    # ceiling here — a class-body survivor gets every referencing spec its shot
    # before being declared.
    def escalation_examples(map, spec_contents, phase1_example_ids, pattern)
      phase1_files = phase1_example_ids.map { |id| BaselineDelta.spec_file_of(id) }.uniq
      spec_contents.filter_map do |abs, content|
        rel = abs.delete_prefix(@config.root.chomp("/") + "/")
        next if phase1_files.include?(rel)
        next unless content.match?(pattern)

        map.examples_for_spec_file(rel)
      end.flatten.uniq.sort
    end

    # Custom operators must exist in the PARENT before Engine analysis:
    # subclassing Operators::Base self-registers, and forks inherit the
    # loaded class. `requires` can't serve — those load inside the fork's
    # setup, after mutations are already planned.
    def load_operators
      @config.operators.each do |f|
        require File.expand_path(f, @config.root)
      rescue LoadError, SyntaxError => e
        raise Error, "operator file not loadable: #{f}: #{e.message}"
      end
    end

    # Line coverage attributes multi-line expressions to their statement anchor
    # line (version-dependently), so a sub-expression mutant's own lines may
    # carry no coverage at all. Look up the whole subject instead: a mutant must
    # run against every example covering any line of its method.
    def coverage_lines(mutation)
      mutation.lines.to_a | mutation.subject.line_range.to_a
    end

    # Class-body lines execute at load time, so line coverage never
    # attributes examples to them. Substitute: every example that covers ANY
    # line of the file (it must have loaded the class), plus the convention
    # spec file's examples. Phase 2 (escalation) widens further before a
    # survivor is declared.
    def examples_for_mutation(mutation, map)
      return map.examples_for(mutation.subject.file, coverage_lines(mutation)) unless mutation.subject.class_body?

      (map.examples_covering_file(mutation.subject.file) |
        map.examples_for_spec_file(convention_spec_rel(mutation.subject.file))).sort
    end

    def convention_spec_rel(file)
      rel = file.delete_prefix(@config.root.chomp("/") + "/").delete_suffix(".rb")
      rest = rel.sub(%r{\A[^/]+/}, "")
      "#{@config.spec_paths.first}/#{rest}_spec.rb"
    end

    def build_reporter
      case @config.format
      when :json then Reporter::Json.new
      when :stryker_json then Reporter::StrykerJson.new(root: @config.root)
      when :github then Reporter::Github.new(root: @config.root)
      else Reporter::Terminal.new
      end
    end

    def preload!
      # Workers run the test suite, so the app must boot in the test
      # environment (the development database may not even exist).
      ENV["RAILS_ENV"] ||= "test"
      @config.requires.each { |f| require File.expand_path(f, @config.root) }
      environment = File.join(@config.root, "config", "environment.rb")
      if @config.requires.empty? && File.exist?(environment)
        require environment
        Rails.application.eager_load! if defined?(Rails)
      end
    end

    def discover_subjects
      paths = @config.paths.empty? ? default_paths : @config.paths
      subjects = paths
        .flat_map { |p| expand_path_arg(p) }
        .uniq
        .reject { |file| excluded?(file) }
        .sort.flat_map { |file| SubjectFinder.call(file) }
      subjects = subjects.reject(&:class_body?) unless @config.class_level
      if @config.subject_filter
        matcher = SubjectMatcher.new(@config.subject_filter)
        subjects = subjects.select { |s| matcher.match?(s.name) }
      end
      if @config.since
        filter = SinceFilter.new(ref: @config.since, root: @config.root)
        subjects = subjects.select { |s| filter.cover?(s) }
      end
      subjects
    end

    # Positional args may be files or directories. Anything else is an error:
    # a mistyped path that silently matched nothing produced a false green
    # (0 subjects, exit 0) — see #23.
    def expand_path_arg(path)
      full = File.expand_path(path, @config.root)
      if File.file?(full)
        raise Error, "not a Ruby file: #{path}" unless full.end_with?(".rb")

        [full]
      elsif Dir.exist?(full)
        Dir[File.join(full, "**", "*.rb")]
      else
        raise Error, "no such file or directory: #{path}"
      end
    end

    def excluded?(file)
      flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
      relative = file.delete_prefix(@config.root.chomp("/") + "/")
      @config.exclude.any? do |pattern|
        # Gitignore-like ergonomics: "lib/gen", "lib/gen/" and "lib/gen/**"
        # all exclude the whole subtree, not just direct children.
        dir = pattern.sub(%r{(/\*\*)?/?\z}, "")
        File.fnmatch?(pattern, relative, flags) ||
          File.fnmatch?("#{dir}/**/*", relative, flags)
      end
    end

    def default_paths
      %w[app lib].select { |p| Dir.exist?(File.join(@config.root, p)) }
    end

    def serial_example?(example_id)
      path = example_id.sub(%r{\A\./}, "")
      @config.serial_patterns.any? { |pattern| path.start_with?(pattern) }
    end

    def preload_spec_helper!
      return if @config.preload_helper == :none

      helper = if @config.preload_helper
                 File.expand_path(@config.preload_helper, @config.root)
               else
                 # Precedence: within each spec path rails_helper wins over
                 # spec_helper; earlier spec paths win over later ones — same
                 # as today for the default ["spec"].
                 @config.spec_paths
                   .flat_map { |sp| ["#{sp}/rails_helper.rb", "#{sp}/spec_helper.rb"] }
                   .map { |p| File.join(@config.root, p) }
                   .find { |p| File.exist?(p) }
               end
      return unless helper && File.exist?(helper)

      # Mirror what `bundle exec rspec` provides before a helper loads:
      # rspec-core itself (helpers call RSpec.configure at the top level) and
      # the default path (spec/) on $LOAD_PATH (rails_helper.rb relies on it
      # for its bare `require "spec_helper"`).
      require "rspec/core"
      spec_dir = File.dirname(helper)
      $LOAD_PATH.unshift(spec_dir) unless $LOAD_PATH.include?(spec_dir)
      require helper
      disarm_simplecov
    end

    # A preloaded helper commonly starts SimpleCov. Its at_exit would fire in
    # THIS parent process at the end of the mutation run, clobbering the
    # project's real coverage data, and minimum_coverage would exit(1) for a
    # bogus reason. Neutralize it.
    def disarm_simplecov
      SimpleCov.at_exit {} if defined?(SimpleCov)
    end

    # Only a run with no subject-level narrowing has fully scanned a file;
    # anything narrower must not prune (or warn about) out-of-scope entries.
    # MAINTENANCE: any future flag that narrows the mutant set below "every
    # subject in the scanned files" MUST be added to this nil-trigger list,
    # or scoped accept runs will clobber out-of-scope ledger entries (#24).
    # --no-class-level drops every class_body subject (discover_subjects), so a
    # file's class-body fingerprint is absent even though the file is scanned;
    # without this guard its accepted ledger entry looks stale and gets pruned.
    def prune_scope(subjects)
      return nil if @config.subject_filter || @config.since || @config.max_mutants || !@config.class_level

      subjects.map { |s| s.file.delete_prefix("#{@config.root}/") }.uniq
    end

    def accept_survivors!(ledger, results, fingerprints, scanned_files)
      survivors = results.select { |r| r.status == :survived }.map { |r| fingerprints[r.mutation] }
      return if survivors.empty?

      ledger.accept!(survivors, fingerprints.values, scanned_files: scanned_files)
    end

    def debug_plan(items, pre_results)
      plan = items.map do |i|
        { "subject" => i.mutation.subject.name, "description" => i.mutation.description,
          "file" => i.mutation.subject.file, "line" => i.mutation.line,
          "lane" => i.lane.to_s, "timeout" => i.timeout.round(2),
          "examples" => i.example_ids.size }
      end
      skipped = pre_results.group_by { |r| r.status.to_s }.transform_values(&:size)
      puts JSON.pretty_generate("planned" => plan, "pre_resolved" => skipped)
      0
    end

    def warn_stale(ledger, all_fingerprints, scanned_files)
      ledger.stale_entries(all_fingerprints, scanned_files: scanned_files).each do |entry|
        warn "active_mutator: stale accepted fingerprint (no matching mutant): #{entry.subject}, #{entry.description}"
      end
      ledger.missing_file_entries(@config.root).each do |entry|
        warn "active_mutator: accepted fingerprint references missing file: #{entry.file} (#{entry.subject})"
      end
    end
  end
end
