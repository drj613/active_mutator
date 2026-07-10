require "fileutils"
require "tmpdir"

# Copies spec/fixtures/tiny_project into a tmpdir so tests can mutate files
# freely. The fixture's Gemfile references the gem by relative path, which
# breaks when copied — rewrite it to an absolute path. Reuses the original
# fixture's installed bundle via BUNDLE_GEMFILE at call sites.
module FixtureCopy
  GEM_ROOT = File.expand_path("../..", __dir__)
  FIXTURE = File.join(GEM_ROOT, "spec/fixtures/tiny_project")

  def with_fixture_copy
    Dir.mktmpdir do |dir|
      root = File.join(dir, "tiny_project")
      FileUtils.cp_r(FIXTURE, root)
      # Resolve symlinks (macOS /var -> /private/var): the baseline hooks record
      # coverage under realpaths (spec_helper's require_relative canonicalizes
      # via __dir__), so `root` must match or diff_coverage drops every record.
      root = File.realpath(root)
      FileUtils.rm_rf(File.join(root, ".open_mutator"))
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
