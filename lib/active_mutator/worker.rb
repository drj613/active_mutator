require "json"
require "set"

module ActiveMutator
  # Runs INSIDE a fork. Insertion order relative to RSpec's setup (which loads
  # the spec files, and with them the app) DIFFERS by mutant kind:
  #
  #   Class-body: insert BEFORE setup. `RSpec.describe SomeClass` binds
  #   `metadata[:described_class]` to the constant AT LOAD TIME, and a class-body
  #   mutant reloads the constant to a NEW object via ClosureReload; a group
  #   loaded first would keep the pre-mutation object and falsely survive. So we
  #   require the subject file, reload, THEN let setup load the groups — every
  #   group binds to the mutated object.
  #
  #   Def: insert AFTER setup. A def mutant class_evals the live method in
  #   place, so it must be the LAST thing to touch that method. Inserting before
  #   setup let a file loaded during spec-load (a concern/decorator/monkeypatch
  #   that reopens the class but isn't transitively required by the subject
  #   file) silently redefine the method back to the original, reporting a false
  #   survivor. Loading everything first, then inserting, closes that window.
  #   Requiring the subject after setup also means spec_helper's load-time setup
  #   runs first, so a subject that depends on it still loads in non-preloaded
  #   projects.
  #
  # The explicit `require` of the subject file guarantees the target constant
  # exists before insertion regardless of preload: preloaded projects
  # (Rails/Zeitwerk, or a preloaded spec helper) already have it in
  # $LOADED_FEATURES so it's a no-op, while non-preloaded projects (plain
  # gems whose spec files require the lib themselves, or --no-preload-helper)
  # get it loaded rather than relying on spec-load to define it.
  #
  # `audit: true` is the --audit-tests pass: fail-fast goes off so every
  # selected example runs, and the report adds every fresh failure in the
  # selection ("killers") and every example that passed ("passed", id =>
  # location), except that passes tagged `active_mutator: :no_kill_ok` go in
  # "ignored". Pending and skipped examples are in none of the lists.
  class Worker
    def self.run(mutation, example_ids, writer, audit: false)
      new(mutation, example_ids, writer, audit: audit).run
    end

    def initialize(mutation, example_ids, writer, audit: false)
      @mutation = mutation
      @example_ids = example_ids
      @writer = writer
      @audit = audit
    end

    def run
      # The mutant lands in THIS process, so a mutant of the id parser or of
      # these methods could rewrite the very code that selects the groups and
      # reports the verdict, before the specs that kill it have run. Bind the
      # originals first. A Worker built later (by a spec) sees the mutant.
      @emit = method(:emit)
      @covering_groups = method(:covering_groups)
      @killer = method(:killer)
      @no_killer_details = method(:no_killer_details)
      @in_selection = method(:in_selection)
      @audit_verdicts = method(:audit_verdicts)
      @failed_examples = method(:failed_examples)
      @all_examples = method(:all_examples)
      @normalize = ExampleId.method(:normalize)
      @group_keys = @example_ids.filter_map { |id| ExampleId.group_key(id) }
      require "rspec/core"
      # Workers run the at_exit hooks tests register. A spec file that
      # requires rspec/autorun registers one that would run the loaded
      # examples again after the report; the rspec command turns it off too.
      RSpec::Core::Runner.disable_autorun!
      devnull = File.open(File::NULL, "w")
      # Sorted so spec files load in the same order whatever the run priority:
      # load order decides constant definitions and shared setup.
      runner = RSpec::Core::Runner.new(RSpec::Core::ConfigurationOptions.new(@example_ids.sort))
      if @mutation.subject.reload?
        require @mutation.subject.file # no-op if already loaded; guarantees the constant exists
        insert_mutation                # BEFORE setup: groups bind described_class to the mutated object
        runner.setup(devnull, devnull) # loads spec files
      else
        runner.setup(devnull, devnull) # loads spec files -> the app, in dependency order
        require @mutation.subject.file # no-op if already loaded; guarantees the constant exists
        insert_mutation                # AFTER load: nothing left can redefine the method back
      end
      # One failure kills the mutant; running the rest of the covering set
      # is pure waste inside the fork. The audit needs every verdict instead.
      RSpec.configuration.fail_fast = @audit ? false : 1
      after_fork_hygiene
      failed_before = @failed_examples.call.dup
      examples_before = @all_examples.call.dup
      code = runner.run_specs(@covering_groups.call)
      failures = @failed_examples.call - failed_before
      verdicts = @audit ? @audit_verdicts.call(failures, @all_examples.call - examples_before) : {}
      if code.zero?
        @emit.call("survived", **verdicts)
      else
        killer = @killer.call(failures)
        @emit.call("killed", killer: killer, details: (@no_killer_details.call(code) unless killer), **verdicts)
      end
    rescue ClosureReload::Skip => e
      @emit.call("skipped", details: e.message)
    rescue ClosureReload::MutantLoadError => e
      # The mutation made the class unloadable; a real suite would fail on it.
      @emit.call("killed", details: "mutated class failed to load: #{e.message}")
    rescue StandardError, ScriptError => e
      @emit.call("error", details: "#{e.class}: #{e.message}")
    end

    private

    # Def mutants class_eval over the live constant; class-body mutants
    # cannot (macros accumulate) and go through whole-file closure reload, as
    # do defs inside `included`/`prepended` blocks (they live on the includer).
    def insert_mutation
      if @mutation.subject.reload?
        ClosureReload.new(@mutation.subject, @mutation.mutated_file_source).call
      else
        Inserter.new.insert(@mutation)
      end
    end

    def after_fork_hygiene
      srand
      if defined?(ActiveRecord::Base)
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ActiveRecord::Base.establish_connection
      end
    end

    def emit(status, details: nil, killer: nil, **verdicts)
      report = { "status" => status, "details" => details }
      report["killer"] = killer if killer
      report.merge!(verdicts.transform_keys(&:to_s))
      @writer.puts(JSON.generate(report))
      @writer.flush if @writer.respond_to?(:flush)
    end

    # RSpec.world holds every group registered in the process, including any
    # top-level groups evaluated while the PARENT preloaded the spec helper
    # (spec/support files with RSpec.describe at load time are common). Those
    # leak into the fork; running them would report their failures as false
    # kills. Run only groups that belong to the covering spec files, in the
    # priority order of @example_ids; groups it does not name keep host order.
    def covering_groups
      covering = @group_keys.map(&:first).to_set
      rank = {}
      @group_keys.each { |key| rank[key] ||= rank.size }
      groups = RSpec.world.ordered_example_groups.each_with_index.select do |group, _|
        covering.include?(group.metadata[:absolute_file_path])
      end
      groups.sort_by do |group, host_index|
        key = [group.metadata[:absolute_file_path], group.metadata[:scoped_id]]
        [rank.fetch(key, rank.size), host_index]
      end.map(&:first)
    end

    def failed_examples = RSpec.configuration.reporter.failed_examples

    def all_examples = RSpec.configuration.reporter.examples

    # The first fresh failure that is one of the examples this mutant ran
    # against, spelled as RSpec reports it; nil when there is none.
    def killer(failures) = @in_selection.call(failures).first

    # Why a failed run has no killer. RSpec marks a failure outside any
    # example, like a spec file that raised on load or a raising suite or
    # after(:context) hook; anything else just exited nonzero.
    def no_killer_details(code)
      return "no covering example failed, but RSpec exited #{code}" unless RSpec.world.non_example_failure

      "no covering example failed; the run failed outside any example " \
        "(a spec file failed to load, or a suite or context hook raised)"
    end

    # The ids of `examples` that this mutant ran against, spelled as RSpec
    # reports them, in run order.
    def in_selection(examples)
      selected = @example_ids.filter_map { |id| @normalize.call(id) }.to_set
      examples.map(&:id).select { |id| selected.include?(@normalize.call(id)) }
    end

    # A passing example tagged `active_mutator: :no_kill_ok` goes in
    # "ignored", not "passed": its owner says it is fine that it kills
    # nothing. A tagged example that fails is still a killer.
    def audit_verdicts(failures, ran)
      passed = ran.select { |example| example.execution_result.status == :passed }
      ignored, passed = passed.partition { |example| example.metadata[:active_mutator] == :no_kill_ok }
      locations = passed.to_h { |example| [example.id, example.location] }
      { killers: @in_selection.call(failures),
        passed: @in_selection.call(passed).to_h { |id| [id, locations.fetch(id)] },
        ignored: @in_selection.call(ignored) }
    end
  end
end
