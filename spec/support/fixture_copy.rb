require "fileutils"
require "tmpdir"

# Copies spec/fixtures/tiny_project into a tmpdir so tests can mutate files
# freely. The fixture's Gemfile references the gem by relative path, which
# breaks when copied — rewrite it to an absolute path. Reuses the original
# fixture's installed bundle via BUNDLE_GEMFILE at call sites.
module FixtureCopy
  GEM_ROOT = File.expand_path("../..", __dir__)
  FIXTURE = File.join(GEM_ROOT, "spec/fixtures/tiny_project")

  # The fixture's Gemfile.lock is gitignored, so a fresh checkout (CI) has
  # neither a lockfile nor the fixture's gems anywhere a subprocess can see
  # them: the outer suite's gems live under Bundler's isolated path (e.g.
  # setup-ruby's vendor/bundle), and fixture subprocesses run unbundled
  # against the default gem home. Without this install-once:
  # - `bundle exec` in the fixture fails outright (empty stdout), and
  # - the first in-fixture run CREATES Gemfile.lock, which flips the
  #   baseline digest set and invalidates a just-written coverage cache.
  def self.ensure_fixture_bundle!
    return if @fixture_bundle_ready

    Bundler.with_unbundled_env do
      ENV["BUNDLE_GEMFILE"] = File.join(FIXTURE, "Gemfile")
      system("bundle", "install", "--quiet", chdir: FIXTURE, out: :err) or
        raise "fixture bundle install failed"
    ensure
      ENV.delete("BUNDLE_GEMFILE")
    end
    @fixture_bundle_ready = true
  end

  def ensure_fixture_bundle! = FixtureCopy.ensure_fixture_bundle!

  def with_fixture_copy
    FixtureCopy.ensure_fixture_bundle!
    Dir.mktmpdir do |dir|
      root = File.join(dir, "tiny_project")
      FileUtils.cp_r(FIXTURE, root)
      # Resolve symlinks (macOS /var -> /private/var): the baseline hooks record
      # coverage under realpaths (spec_helper's require_relative canonicalizes
      # via __dir__), so `root` must match or diff_coverage drops every record.
      root = File.realpath(root)
      FileUtils.rm_rf(File.join(root, ".active_mutator"))
      gemfile = File.join(root, "Gemfile")
      File.write(gemfile, File.read(gemfile).sub('path: "../../.."', %(path: "#{GEM_ROOT}")))
      Bundler.with_unbundled_env do
        ENV["BUNDLE_GEMFILE"] = gemfile
        system("bundle", "install", "--quiet", chdir: root, out: :err) or raise "fixture bundle failed"
        yield root
      ensure
        ENV.delete("BUNDLE_GEMFILE")
      end
    end
  end
end

RSpec.configure { |c| c.include FixtureCopy }
