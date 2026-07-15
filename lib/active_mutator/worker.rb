require "json"
require "set"

module ActiveMutator
  # Runs INSIDE a fork. Order is critical: RSpec's setup phase loads the spec
  # files, whose spec_helper/rails_helper loads the application. Only THEN
  # can the mutation be inserted over the loaded original. Insert-first would
  # NameError on any project not preloaded in the parent (all non-Rails
  # projects), and loading app code after insertion would silently restore
  # the original method.
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
      runner.setup(devnull, devnull)   # loads spec files -> loads the app
      # One failure kills the mutant; running the rest of the covering set
      # is pure waste inside the fork.
      RSpec.configuration.fail_fast = 1
      Inserter.new.insert(@mutation)   # now the target constant exists
      after_fork_hygiene
      code = runner.run_specs(covering_groups)
      emit(code.zero? ? "survived" : "killed")
    rescue StandardError, ScriptError => e
      emit("error", details: "#{e.class}: #{e.message}")
    end

    private

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
