require "digest"
require "json"

module ActiveMutator
  class RunInputs
    attr_reader :source_digests

    def initialize(config)
      @config = config
      @root = config.root
      @spec_paths = config.spec_paths.map { |path| File.expand_path(path, @root) + "/" }
      @source_digests = {}
      @load_path = $LOAD_PATH.dup
    end

    def setup(status_file: nil)
      @manifest ||= setup_manifest
      fingerprint(@manifest, status_file)
    end

    def analyze(subjects)
      subjects.group_by(&:file).flat_map do |file, members|
        source = File.read(file)
        @source_digests[file] = Digest::SHA256.hexdigest(source)
        members.map { |subject| Engine.new.analyze(subject, source: source) }
      end
    end

    def stable?(map)
      setup(status_file: map.status_file) == fingerprint(setup_manifest, map.status_file) &&
        @source_digests.all? { |path, digest| file_digest(path) == digest } &&
        map.digests.all? { |path, digest| file_digest(path) == digest }
    end

    def spec_digests(map)
      map.digests.select { |path, _| spec_file?(File.expand_path(path, @root)) }
    end

    private

    def spec_file?(absolute)
      @spec_paths.any? { |prefix| absolute.start_with?(prefix) }
    end

    def setup_manifest
      require "rspec/core"
      options = Dir.chdir(@root) { RSpec::Core::ConfigurationOptions.new([]).options }
      lib_paths = options.fetch(:libs) + ["lib", options.fetch(:default_path, "spec")] + @load_path
      inputs = [".rspec", ".rspec-local", "Gemfile", "Gemfile.lock", "db/schema.rb", "db/structure.sql"]
      inputs << File.expand_path("~/.rspec")
      inputs << File.join(ENV.fetch("XDG_CONFIG_HOME", File.expand_path("~/.config")), "rspec", "options")
      inputs.concat(Dir.glob("config/**/*", base: @root))
      @spec_paths.each do |prefix|
        inputs.concat(Dir.glob("**/*", File::FNM_DOTMATCH, base: prefix).filter_map do |relative|
          path = File.join(prefix, relative)
          path if !relative.end_with?("_spec.rb") && File.file?(path)
        end)
      end
      explicit = [*@config.operators, *@config.requires, @config.preload_helper].grep(String)
      inputs.concat(explicit.flat_map { |file| require_files(file) })
      inputs.concat(options.fetch(:requires).flat_map do |name|
        candidates = [name]
        candidates.concat(lib_paths.map { |dir| File.join(dir, name) }) unless name.start_with?(".", "/")
        candidates.flat_map { |file| require_files(file) }
      end)

      files = inputs.compact.uniq.sort.to_h do |file|
        absolute = File.expand_path(file, @root)
        [absolute.delete_prefix("#{@root}/"), file_digest(absolute)]
      end
      gem_dir = File.expand_path(__dir__)
      gem_files = Dir.glob("**/*.rb", base: gem_dir).sort.to_h do |relative|
        [relative, file_digest(File.join(gem_dir, relative))]
      end
      runtime = [
        VERSION, RUBY_DESCRIPTION, ENV["SPEC_OPTS"], ENV.fetch("RAILS_ENV", "test"),
        @config.spec_paths, @config.operators, @config.requires, @config.preload_helper,
        @config.class_level_closure_cap
      ]
      [runtime, files, gem_files]
    end

    def fingerprint(manifest, status_file)
      runtime, files, gem_files = manifest
      files = files.except(status_file) if status_file
      Digest::SHA256.hexdigest(JSON.generate([runtime, files, gem_files]))
    end

    def require_files(file)
      path = File.expand_path(file, @root)
      [path, "#{path}.rb", "#{path}.#{RbConfig::CONFIG.fetch("DLEXT")}"].select { |candidate| File.file?(candidate) }
    end

    def file_digest(file)
      Digest::SHA256.file(File.expand_path(file, @root)).hexdigest
    rescue Errno::ENOENT, Errno::EISDIR
      nil
    end
  end
end
