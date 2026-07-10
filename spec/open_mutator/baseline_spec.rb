require "fileutils"

RSpec.describe OpenMutator::Baseline, :integration do
  let(:root) { File.expand_path("../fixtures/tiny_project", __dir__) }
  let(:cache_dir) { File.join(root, ".open_mutator") }

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
        .to raise_error(OpenMutator::BaselineFailed)
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
end
