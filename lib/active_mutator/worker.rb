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
  class Worker
    def self.run(mutation, example_ids, writer)
      new(mutation, example_ids, writer).run
    end

    def initialize(mutation, example_ids, writer)
      @mutation = mutation
      @example_ids = example_ids
      @writer = writer
    end

    def run
      require "rspec/core"
      devnull = File.open(File::NULL, "w")
      runner = RSpec::Core::Runner.new(RSpec::Core::ConfigurationOptions.new(@example_ids))
      if @mutation.subject.class_body?
        require @mutation.subject.file # no-op if already loaded; guarantees the constant exists
        insert_mutation                # BEFORE setup: groups bind described_class to the mutated object
        runner.setup(devnull, devnull) # loads spec files
      else
        runner.setup(devnull, devnull) # loads spec files -> the app, in dependency order
        require @mutation.subject.file # no-op if already loaded; guarantees the constant exists
        insert_mutation                # AFTER load: nothing left can redefine the method back
      end
      # One failure kills the mutant; running the rest of the covering set
      # is pure waste inside the fork.
      RSpec.configuration.fail_fast = 1
      after_fork_hygiene
      code = runner.run_specs(covering_groups)
      emit(code.zero? ? "survived" : "killed")
    rescue ClosureReload::Skip => e
      emit("skipped", details: e.message)
    rescue ClosureReload::MutantLoadError => e
      # The mutation made the class unloadable; a real suite would fail on it.
      emit("killed", details: "mutated class failed to load: #{e.message}")
    rescue StandardError, ScriptError => e
      emit("error", details: "#{e.class}: #{e.message}")
    end

    private

    # Def mutants class_eval over the live constant; class-body mutants
    # cannot (macros accumulate) and go through whole-file closure reload.
    def insert_mutation
      if @mutation.subject.class_body?
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

    def emit(status, details: nil)
      @writer.puts(JSON.generate("status" => status, "details" => details))
      @writer.flush if @writer.respond_to?(:flush)
    end

    # RSpec.world holds every group registered in the process, including any
    # top-level groups evaluated while the PARENT preloaded the spec helper
    # (spec/support files with RSpec.describe at load time are common). Those
    # leak into the fork; running them would report their failures as false
    # kills. Run only groups that belong to the covering spec files.
    def covering_groups
      covering = @example_ids
                 .map { |id| File.expand_path(id[/\A(.+?)\[/, 1]) }
                 .to_set
      RSpec.world.ordered_example_groups.select do |group|
        covering.include?(group.metadata[:absolute_file_path])
      end
    end
  end
end
