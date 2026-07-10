module OpenMutator
  class Runner
    def initialize(config, reporter: nil)
      @config = config
      @reporter = reporter || build_reporter
    end

    def call
      preload!
      map = Baseline.new(root: @config.root).coverage_map(force: @config.force_baseline)
      subjects = discover_subjects
      analyses = subjects.map { |s| Engine.new.analyze(s) }
      mutations = analyses.flat_map(&:mutations)
      invalid_count = analyses.sum(&:invalid_count)

      items, uncovered = plan_work(mutations, map)
      uncovered.each { |r| @reporter.on_result(r) }
      scheduler = Scheduler.new(jobs: @config.jobs, on_result: @reporter.method(:on_result))
      results = scheduler.run(items) + uncovered

      @reporter.summary(results, invalid_count: invalid_count)
      exit_code(results)
    end

    # Returns [work_items, uncovered_results]. Public for unit testing.
    def plan_work(mutations, map)
      items = []
      uncovered = []
      mutations.each do |mutation|
        example_ids = map.examples_for(mutation.subject.file, mutation.lines)
        if example_ids.empty?
          uncovered << Result.new(mutation: mutation, status: :uncovered, details: nil)
        else
          timeout = map.time_for(example_ids) * @config.timeout_factor + @config.timeout_floor
          items << WorkItem.new(mutation: mutation, example_ids: example_ids, timeout: timeout)
        end
      end
      [items, uncovered]
    end

    def exit_code(results)
      results.any? { |r| r.status == :survived } ? 1 : 0
    end

    private

    def build_reporter
      @config.format == :json ? Reporter::Json.new : Reporter::Terminal.new
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
        .flat_map { |p| Dir[File.join(@config.root, p, "**", "*.rb")] }
        .sort.flat_map { |file| SubjectFinder.call(file) }
      subjects = subjects.select { |s| s.name == @config.subject_filter } if @config.subject_filter
      if @config.since
        filter = SinceFilter.new(ref: @config.since, root: @config.root)
        subjects = subjects.select { |s| filter.cover?(s) }
      end
      subjects
    end

    def default_paths
      %w[app lib].select { |p| Dir.exist?(File.join(@config.root, p)) }
    end
  end
end
