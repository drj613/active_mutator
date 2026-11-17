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
  # covers; one gap (an inconclusive fork, a skip) leaves it not judged.
  class TestAudit
    # flagged: Flags, by id. cleared: how many examples were seen to kill.
    # not_judged: ids with no pass against some killable mutant. kills:
    # mutation => ids the audit saw kill it. mutants_run: audit forks spent.
    Report = Data.define(:flagged, :cleared, :not_judged, :kills, :mutants_run)
    # killable: how many killed def mutants the example covers.
    Flag = Data.define(:id, :location, :killable)

    # mutation => ids the audit saw kill it so far; on a stop, what to keep.
    attr_reader :kills

    # example_ids: mutation => the ids it ran against in phase 1.
    # build: ->(mutation, ids) { WorkItem }; run: ->(items) { results }.
    def initialize(results:, example_ids:, width:, build:, run:)
      @results = results
      @example_ids = example_ids
      @width = width
      @build = build
      @run = run
      @kills = {}
    end

    def call
      defs = @results.reject { |r| r.mutation.subject.class_body? }
      # Only kills carry killers (Scheduler#verified_killers).
      killable = defs.select { |r| r.killed_by.any? }
      # A kill of any mutant, class-body included, clears its killer.
      @cleared = @results.flat_map(&:killed_by).to_set { |id| key(id) }
      @passes = {}
      runs = audit(killable.to_h { |r| [r.mutation, @example_ids.fetch(r.mutation, [])] })
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

    def next_round(pending)
      pending.filter_map do |mutation, ids|
        suspects = ids.reject { |id| @cleared.include?(key(id)) }
        [mutation, suspects] unless suspects.empty?
      end.each_with_index.sort_by { |(_, suspects), i| [-suspects.size, i] }.first(@width).map(&:first)
    end

    def learn(result)
      return unless conclusive?(result)

      result.killed_by.each { |id| @cleared << key(id) }
      (@kills[result.mutation] ||= []).concat(result.killed_by) if result.killed_by.any?
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
      flagged, not_judged = rest.partition { |id| @passes.dig(key(id), 1)&.size == covering[key(id)] }
      flags = flagged.sort.map { |id| Flag.new(id: id, location: @passes.dig(key(id), 0), killable: covering[key(id)]) }
      Report.new(flagged: flags, cleared: cleared.size, not_judged: not_judged.sort, kills: @kills, mutants_run: runs)
    end

    # ./spec/a_spec.rb[1:1] and its absolute spelling are one example.
    def key(id) = ExampleId.normalize(id) || id
  end
end
