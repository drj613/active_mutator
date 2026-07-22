require "json"
require "set"

module ActiveMutator
  # Runs INSIDE a fork. Order is critical: the mutation must be inserted
  # BEFORE RSpec's setup phase loads the spec files. The parent already
  # preloaded the app (Runner#preload! / #preload_spec_helper! requires the
  # library before forking), so the target constant exists in the fork
  # independently of spec-file loading. Inserting first matters because
  # `RSpec.describe SomeClass` binds `metadata[:described_class]` to the
  # constant AT LOAD TIME: a class-body mutant reloads the constant to a NEW
  # object via ClosureReload, so a group loaded first would keep the
  # pre-mutation object and falsely survive. Insert first and every group
  # binds to the mutated object. (Def mutants class_eval the live class in
  # place, same object either way, but share the ordering harmlessly.)
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
      insert_mutation                  # BEFORE setup: groups bind described_class to the mutated object
      runner.setup(devnull, devnull)   # loads spec files
      # One failure kills the mutant; running the rest of the covering set
      # is pure waste inside the fork.
      RSpec.configuration.fail_fast = 1
      after_fork_hygiene
      code = runner.run_specs(covering_groups)
      emit(code.zero? ? "survived" : "killed")
    rescue ClosureReload::Skip => e
      emit("skipped", details: e.message)
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
