require "digest"
require "fileutils"
require "json"

module OpenMutator
  # Runs the host suite once, instrumented, in a subprocess. Produces and
  # caches the CoverageMap. Invalidation is coarse: any digest change in
  # {app,lib,spec}/**/*.rb triggers a full re-run.
  class Baseline
    def initialize(root:, cache_dir: File.join(root, ".open_mutator"))
      @root = root
      @cache_dir = cache_dir
      @out_path = File.join(cache_dir, "coverage.json")
    end

    def coverage_map(force: false)
      digests = current_digests
      if !force && File.exist?(@out_path)
        map = CoverageMap.load(@out_path)
        return map if map.fresh?(digests)
      end
      run_baseline!
      stamp_digests(digests)
      CoverageMap.load(@out_path)
    end

    private

    def run_baseline!
      FileUtils.mkdir_p(@cache_dir)
      env = {
        "OPEN_MUTATOR_ROOT" => @root,
        "OPEN_MUTATOR_BASELINE_OUT" => @out_path,
        # RUBYOPT, not `rspec --require`: project .rspec requires (spec_helper
        # → app code) run before command-line requires, and Coverage misses
        # everything loaded before Coverage.start. -r fires before rspec boots.
        #
        # Absolute path, not the gem-relative "open_mutator/baseline_hooks":
        # `bundle exec` appends its own "-rbundler/setup" to RUBYOPT AFTER
        # whatever RUBYOPT already held, so a bare gem-relative require here
        # would run before Bundler has put this gem's lib/ on $LOAD_PATH and
        # raise LoadError. An absolute path bypasses $LOAD_PATH entirely.
        "RUBYOPT" => "-r#{File.expand_path("baseline_hooks", __dir__)}"
      }
      # out: :err — the subprocess suite's progress output must not pollute
      # our stdout (breaks `--format json` consumers).
      ok = system(env, "bundle", "exec", "rspec", chdir: @root, out: :err)
      raise BaselineFailed, "baseline suite failed — fix the suite before mutating" unless ok
      raise BaselineFailed, "baseline produced no coverage output" unless File.exist?(@out_path)
    end

    def stamp_digests(digests)
      data = JSON.parse(File.read(@out_path))
      data["digests"] = digests
      File.write(@out_path, JSON.generate(data))
    end

    def current_digests
      Dir[File.join(@root, "{app,lib,spec}/**/*.rb")].sort.to_h do |f|
        [f.delete_prefix("#{@root}/"), Digest::SHA256.file(f).hexdigest]
      end
    end
  end
end
