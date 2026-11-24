require "set"

module ActiveMutator
  # The --audit-tests pass (#54): find examples that cover mutants other
  # examples kill, yet never kill one themselves.
  #
  # The normal run stops at the first failure, so an example never named as
  # a killer may just never have run first. The suspects are the examples
  # that covered a killed def mutant and were never named. Each killed
  # mutant with suspects left runs once more, against those suspects only,
  # on a worker with fail-fast off. A suspect is cleared the moment it kills
  # anything, so good tests drop out after a fork or two; only a test that
  # truly kills nothing pays for every mutant it covers.
  #
  # Mutants go in rounds of `width`, the most suspects first, so a round can
  # clear suspects before the next one is built.
  #
  # Only def mutants are judged. A class-body mutant runs against every spec
  # that loads its file (and phase 2 adds every spec naming the constant), so
  # passing one says nothing about a test. A kill with no killer (the mutated
  # class failed to load) and a timed-out, errored, or skipped audit fork
  # blame nobody. Pending and skipped examples never count as passes. A
  # suspect is flagged only if it passed against every killed mutant it
  # covers; one gap (an inconclusive fork, a skip) leaves it not judged. A
  # passing example tagged `active_mutator: :no_kill_ok` is listed as
  # ignored unless it kills a mutant.
  class TestAudit
    # flagged: Flags, by id. cleared: how many examples were seen to kill.
    # ignored: ids of tagged examples that never killed. not_judged: ids
    # with no pass against some killable mutant. kills: mutation => ids the
    # audit saw kill it. mutants_run: audit forks spent. fail_on_flags: set
    # by the runner under --fail-on-no-kills.
    Report = Data.define(:flagged, :cleared, :ignored, :not_judged, :kills, :mutants_run, :fail_on_flags) do
      def initialize(flagged:, cleared:, not_judged:, kills:, mutants_run:, ignored: [], fail_on_flags: false)
        super
      end

      def failing? = fail_on_flags && !flagged.empty?
    end
    # killable: how many killed def mutants the example covers.
    Flag = Data.define(:id, :location, :killable)

    # mutation => ids the audit saw kill it so far; on a stop, what to keep.
    attr_reader :kills

    # Worker results with the audit evidence safe to carry to another run.
    attr_reader :evidence

    # example_ids: mutation => the ids it ran against in phase 1.
    # build: ->(mutation, ids) { WorkItem }; run: ->(items) { results }.
    def initialize(results:, example_ids:, width:, build:, run:, retain_evidence: false)
      @results = results
      @example_ids = example_ids
      @width = width
      @build = build
      @run = run
      @kills = {}
      @retain_evidence = retain_evidence
      @evidence = {}
      @keys = {}
    end

    def call
      defs = @results.reject { |r| r.mutation.subject.class_body? }
      # Only kills carry killers (Scheduler#verified_killers).
      killable = defs.select { |r| r.killed_by.any? }
      # A kill of any mutant, class-body included, clears its killer.
      @cleared = @results.flat_map(&:killed_by).to_set { |id| key(id) }
      @passes = {}
      @ignored = Set.new
      @ignored_pairs = {}
      @results.select(&:carried).each do |result|
        record_ignored(result)
        record_passes(result)
      end
      runs = audit(killable.to_h { |r| [r.mutation, @example_ids.fetch(r.mutation, []).dup] })
      universe = defs.flat_map { |r| @example_ids.fetch(r.mutation, []) }.uniq { |id| key(id) }
      report(universe, killable, runs)
    end

    private

    # Runs rounds until no killed mutant has a suspect left; returns the
    # number of forks spent.
    def audit(pending)
      runs = 0
      loop do
        round = next_round(pending)
        return runs if round.empty?

        round.each { |mutation, _| pending.delete(mutation) }
        runs += round.size
        run_round(round).each { |r| learn(r) }
      end
    end

    # A stop mid-round still learns from the forks that finished.
    def run_round(round)
      @run.call(round.map { |mutation, ids| @build.call(mutation, ids) })
    rescue Aborted => e
      e.results.each { |r| learn(r) }
      raise
    end

    # Suspects only ever drop out, so each round keeps what is left and
    # forgets mutants with none.
    def next_round(pending)
      pending.each do |mutation, ids|
        ids.reject! do |id|
          example = key(id)
          @cleared.include?(example) || @ignored_pairs[mutation]&.include?(example) ||
            @passes.dig(example, 1)&.include?(mutation)
        end
      end
      pending.reject! { |_, suspects| suspects.empty? }
      pending.each_with_index.sort_by { |(_, suspects), i| [-suspects.size, i] }.first(@width).map(&:first)
    end

    def learn(result)
      # A tag is a fact about the example, whatever the verdict.
      conclusive = conclusive?(result)
      if @retain_evidence
        @evidence[result.mutation] = conclusive ? result : result.with(passed: {})
      end
      record_ignored(result)
      return unless conclusive

      record_passes(result)

      result.killed_by.each { |id| @cleared << key(id) }
      (@kills[result.mutation] ||= []).concat(result.killed_by) if result.killed_by.any?
    end

    def record_ignored(result)
      return if result.ignored.empty?

      examples = result.ignored.to_set { |id| key(id) }
      @ignored.merge(examples)
      @ignored_pairs[result.mutation] = examples if result.carried
    end

    def record_passes(result)
      result.passed.each do |id, location|
        (@passes[key(id)] ||= [location, Set.new]).last << result.mutation
      end
    end

    def conclusive?(result)
      case result.status
      when :survived then true
      when :killed then result.killed_by.any?
      else false
      end
    end

    def report(universe, killable, runs)
      covering = Hash.new(0)
      killable.each { |r| @example_ids.fetch(r.mutation, []).map { |id| key(id) }.uniq.each { |k| covering[k] += 1 } }
      cleared, rest = universe.partition { |id| @cleared.include?(key(id)) }
      ignored, rest = rest.partition { |id| @ignored.include?(key(id)) }
      flagged, not_judged = rest.partition { |id| @passes.dig(key(id), 1)&.size == covering[key(id)] }
      flags = flagged.sort.map { |id| Flag.new(id: id, location: @passes.dig(key(id), 0), killable: covering[key(id)]) }
      Report.new(flagged: flags, cleared: cleared.size, ignored: ignored.sort, not_judged: not_judged.sort,
                 kills: @kills, mutants_run: runs)
    end

    # ./spec/a_spec.rb[1:1] and its absolute spelling are one example.
    # Memoized: a large suite has millions of mutant-example pairs.
    def key(id) = @keys[id] ||= ExampleId.normalize(id) || id
  end
end
