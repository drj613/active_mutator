require "json"
require "open3"
require "fileutils"

# Proves class-level mutation works end-to-end through closure reload:
#   - class-body mutants of User (validates deletion, presence flip) are KILLED,
#   - a MODULE class-body mutant of Auditable (audit -> "") is KILLED — which is
#     only possible if reloading the module closure propagated into User via
#     `include` (User must be reloaded for audit_tag to change).
RSpec.describe "class_level_project end-to-end", :e2e do
  let(:root) { File.expand_path("../fixtures/class_level_project", __dir__) }

  before do
    # This fixture's bundle isn't managed by FixtureCopy (tiny_project-only),
    # so install it here — same install-once concern as ensure_fixture_bundle!.
    Bundler.with_unbundled_env do
      system({ "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
             "bundle", "install", "--quiet",
             chdir: root, out: :err) or raise "fixture bundle install failed"
    end
  end
  after { FileUtils.rm_rf(File.join(root, ".active_mutator")) }

  it "kills class-body mutants of User and Auditable via closure reload" do
    stdout, stderr, _status = Bundler.with_unbundled_env do
      Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
        "bundle", "exec", "active_mutator", "lib", "--format", "json", "--jobs", "2",
        chdir: root
      )
    end

    data = begin
      JSON.parse(stdout)
    rescue JSON::ParserError
      raise "active_mutator produced unparseable stdout: #{stdout.inspect}\nstderr:\n#{stderr}"
    end
    results = data.fetch("results")
    counts = data.fetch("counts")

    killed = lambda do |subject, description|
      results.any? do |r|
        r["subject"] == subject && r["description"] == description && r["status"] == "killed"
      end
    end

    # 1. User class-body: validates deletion + presence flip are killed
    #    (pinned by valid?/invalid specs, including the described_class one).
    expect(killed.call("User (class body)", "delete `validates :email, presence: true`"))
      .to be(true), stderr
    expect(killed.call("User (class body)", "replace `true` with `false`"))
      .to be(true), stderr

    # 2. Auditable module class-body: replacing "audit" with "" is killed —
    #    proving closure reload propagated a MODULE mutation through `include`.
    expect(killed.call("Auditable (class body)", "replace string with \"\""))
      .to be(true), stderr

    # 3. killed-count >= 3 (not an exact score: operator-catalog growth must
    #    not break this test).
    expect(counts.fetch("killed", 0)).to be >= 3

    # 4. No mutants errored out (a class-body mutant that ERRORs is a real bug).
    expect(counts.fetch("error", 0)).to eq(0)

    # Both class-body subjects were actually produced for the fixture.
    subjects = results.map { |r| r["subject"] }.uniq
    expect(subjects).to include("User (class body)", "Auditable (class body)")
  end
end
