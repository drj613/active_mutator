require "fileutils"
require "tmpdir"

RSpec.describe ActiveMutator::Baseline, :integration do
  let(:root) { File.expand_path("../fixtures/tiny_project", __dir__) }
  let(:cache_dir) { File.join(root, ".active_mutator") }

  before { ensure_fixture_bundle! }
  after { FileUtils.rm_rf(cache_dir) }

  def run_in_fixture
    Bundler.with_unbundled_env do
      ENV["BUNDLE_GEMFILE"] = File.join(root, "Gemfile")
      yield
    ensure
      ENV.delete("BUNDLE_GEMFILE")
    end
  end

  it "runs an instrumented baseline and returns a usable map" do
    map = run_in_fixture { described_class.new(root: root).coverage_map }
    calculator = File.join(root, "lib/calculator.rb")
    # eligible? body (lines 3-7) is covered:
    expect(map.examples_for(calculator, 3..3)).not_to be_empty
    # untested_helper body (`42`, line 16) is not:
    expect(map.examples_for(calculator, 16..16)).to eq([])
    # cache dir must ignore its own contents (never committed by hosts):
    expect(File.read(File.join(cache_dir, ".gitignore"))).to eq("*\n")
  end

  it "reuses a fresh cache without re-running" do
    baseline = described_class.new(root: root)
    run_in_fixture { baseline.coverage_map }
    mtime = File.mtime(File.join(cache_dir, "coverage.json"))
    run_in_fixture { baseline.coverage_map }
    expect(File.mtime(File.join(cache_dir, "coverage.json"))).to eq(mtime)
  end

  it "raises BaselineFailed when the suite is red" do
    broken_spec = File.join(root, "spec", "broken_spec.rb")
    File.write(broken_spec, "RSpec.describe('x') { it { expect(1).to eq(2) } }\n")
    begin
      expect { run_in_fixture { described_class.new(root: root).coverage_map } }
        .to raise_error(ActiveMutator::BaselineFailed)
    ensure
      File.delete(broken_spec)
    end
  end

  it "includes Gemfile.lock and .rspec in the digest set" do
    baseline = described_class.new(root: root)
    digests = baseline.send(:current_digests)
    expect(digests).to have_key("Gemfile.lock")
    expect(digests).to have_key(".rspec")
  end

  describe "spec_paths" do
    it "includes custom spec paths in the digest scan" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test"))
        File.write(File.join(root, "test/a_spec.rb"), "A")
        baseline = described_class.new(root: root, spec_paths: ["test"])
        digests = baseline.send(:current_digests)
        expect(digests).to have_key("test/a_spec.rb")
      end
    end

    it "exports spec paths to the baseline subprocess env" do
      baseline = described_class.new(root: "/proj", spec_paths: ["test", "engines/foo/spec"])
      env = baseline.send(:baseline_env, "/proj/.active_mutator/coverage.json")
      expect(env["ACTIVE_MUTATOR_SPEC_PATHS"]).to eq("test:engines/foo/spec")
    end
  end
end
