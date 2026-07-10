require "digest"
require "fileutils"
require "json"

module ActiveMutator
  # Runs the host suite once, instrumented, in a subprocess. Produces and
  # caches the CoverageMap. Invalidation is coarse: any digest change in
  # {app,lib,spec}/**/*.rb triggers a full re-run.
  class Baseline
    def initialize(root:, cache_dir: File.join(root, ".active_mutator"))
      @root = root
      @cache_dir = cache_dir
      @out_path = File.join(cache_dir, "coverage.json")
    end

    attr_reader :last_refresh

    def coverage_map(force: false)
      digests = current_digests
      if !force && File.exist?(@out_path)
        map = CoverageMap.load(@out_path)
        if map.fresh?(digests)
          @last_refresh = :cached
          return map
        end
        if map.version == 2
          delta = BaselineDelta.compute(old_digests: stored_digests(map), new_digests: digests,
                                        coverage_map: map, root: @root)
          unless delta.full?
            run_partial!(delta)
            stamp_digests(digests)
            @last_refresh = :partial
            return CoverageMap.load(@out_path)
          end
        end
      end
      run_baseline!
      stamp_digests(digests)
      @last_refresh = :full
      CoverageMap.load(@out_path)
    end

    private

    def run_baseline!
      FileUtils.mkdir_p(@cache_dir)
      env = baseline_env(@out_path)
      # out: :err: the subprocess suite's progress output must not pollute
      # our stdout (breaks `--format json` consumers).
      ok = system(env, "bundle", "exec", "rspec", chdir: @root, out: :err)
      raise BaselineFailed, "baseline suite failed, fix the suite before mutating" unless ok
      raise BaselineFailed, "baseline produced no coverage output" unless File.exist?(@out_path)
    end

    def baseline_env(out_path)
      {
        "ACTIVE_MUTATOR" => "1",
        "ACTIVE_MUTATOR_ROOT" => @root,
        "ACTIVE_MUTATOR_BASELINE_OUT" => out_path,
        # RUBYOPT, not `rspec --require`: project .rspec requires (spec_helper
        # → app code) run before command-line requires, and Coverage misses
        # everything loaded before Coverage.start. -r fires before rspec boots.
        #
        # Absolute path, not the gem-relative "active_mutator/baseline_hooks":
        # `bundle exec` appends its own "-rbundler/setup" to RUBYOPT AFTER
        # whatever RUBYOPT already held, so a bare gem-relative require here
        # would run before Bundler has put this gem's lib/ on $LOAD_PATH and
        # raise LoadError. An absolute path bypasses $LOAD_PATH entirely.
        "RUBYOPT" => "-r#{File.expand_path("baseline_hooks", __dir__)}"
      }
    end

    def stored_digests(map)
      JSON.parse(File.read(@out_path)).fetch("digests", {})
    end

    def run_partial!(delta)
      targets = delta.rerun_spec_files + delta.rerun_example_ids
      partial_out = File.join(@cache_dir, "partial.json")
      if targets.any?
        env = baseline_env(partial_out)
        ok = system(env, "bundle", "exec", "rspec", *targets, chdir: @root, out: :err)
        raise BaselineFailed, "partial baseline run failed, fix the suite before mutating" unless ok
        raise BaselineFailed, "partial baseline produced no output" unless File.exist?(partial_out)
      end
      merge_partial!(partial_out, delta)
    ensure
      FileUtils.rm_f(partial_out) if partial_out
    end

    def merge_partial!(partial_out, delta)
      cache = JSON.parse(File.read(@out_path))
      part = File.exist?(partial_out) ? JSON.parse(File.read(partial_out)) : { "records" => {}, "times" => {} }

      rerun_prefixes = delta.rerun_spec_files.map { |rel| "#{rel}[" }
      obsolete = lambda do |example_id|
        bare = example_id.sub(%r{\A\./}, "")
        delta.rerun_example_ids.include?(example_id) ||
          delta.drop_example_ids.include?(example_id) ||
          rerun_prefixes.any? { |p| bare.start_with?(p) }
      end

      cache["records"].reject! { |id, _| obsolete.call(id) }
      cache["times"].reject! { |id, _| obsolete.call(id) }
      cache["records"].each_value do |hits|
        hits.reject! { |(path, _)| delta.drop_source_files.include?(path) }
      end
      cache["records"].merge!(part.fetch("records", {}))
      cache["times"].merge!(part.fetch("times", {}))
      AtomicFile.write(@out_path, JSON.generate(cache))
    end

    def stamp_digests(digests)
      data = JSON.parse(File.read(@out_path))
      data["digests"] = digests
      AtomicFile.write(@out_path, JSON.generate(data))
    end

    def current_digests
      files = Dir[File.join(@root, "{app,lib,spec}/**/*.rb")].sort
      files += [File.join(@root, "Gemfile.lock"), File.join(@root, ".rspec")].select { |f| File.exist?(f) }
      files.to_h { |f| [f.delete_prefix("#{@root}/"), Digest::SHA256.file(f).hexdigest] }
    end
  end
end
