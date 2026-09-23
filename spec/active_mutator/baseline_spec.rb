require "fileutils"
require "tmpdir"

RSpec.describe ActiveMutator::Baseline do
  let(:root) { File.expand_path("../fixtures/tiny_project", __dir__) }
  let(:cache_dir) { File.join(root, ".active_mutator") }

  context "with the tiny fixture's real suite", :integration do
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
  end

  describe "aborted-run detection" do
    def payload(records:, expected: :omit)
      data = { "version" => 2, "records" => records, "times" => {} }
      data["expected_examples"] = expected unless expected == :omit
      data
    end

    it "raises when the subprocess recorded fewer examples than it expected to run" do
      data = payload(records: { "./spec/a_spec.rb[1:1]" => [] }, expected: 3)
      expect { described_class.new(root: "/proj").send(:verify_complete!, data) }
        .to raise_error(ActiveMutator::BaselineFailed, /1 of 3/)
    end

    it "accepts a complete run" do
      data = payload(records: { "./spec/a_spec.rb[1:1]" => [] }, expected: 1)
      expect { described_class.new(root: "/proj").send(:verify_complete!, data) }.not_to raise_error
    end

    it "accepts a payload without an expected count (pre-0.4.0 hooks)" do
      data = payload(records: {})
      expect { described_class.new(root: "/proj").send(:verify_complete!, data) }.not_to raise_error
    end
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

    describe "cache invalidation on spec_paths change" do
      def write_cache(out_path, digests, spec_paths: :omit)
        data = { "version" => 2, "records" => {}, "times" => {}, "digests" => digests }
        data["spec_paths"] = spec_paths unless spec_paths == :omit
        File.write(out_path, JSON.generate(data))
      end

      it "forces a full refresh when the cached spec_paths differ from the configured ones, even if digests match" do
        Dir.mktmpdir do |root|
          cache_dir = File.join(root, ".active_mutator")
          FileUtils.mkdir_p(cache_dir)
          out_path = File.join(cache_dir, "coverage.json")
          baseline = described_class.new(root: root, spec_paths: ["test"], cache_dir: cache_dir)
          digests = baseline.send(:current_digests)
          write_cache(out_path, digests, spec_paths: ["spec"])
          allow(baseline).to receive(:run_baseline!).and_return("version" => 2, "records" => {}, "times" => {})

          map = baseline.coverage_map

          expect(baseline.last_refresh).to eq(:full)
          expect(baseline).to have_received(:run_baseline!)
          expect(map).to be_a(ActiveMutator::CoverageMap)
        end
      end

      it "does not force a full refresh for a pre-0.4.0 cache (no spec_paths key) under the default config" do
        Dir.mktmpdir do |root|
          cache_dir = File.join(root, ".active_mutator")
          FileUtils.mkdir_p(cache_dir)
          out_path = File.join(cache_dir, "coverage.json")
          baseline = described_class.new(root: root, cache_dir: cache_dir)
          digests = baseline.send(:current_digests)
          write_cache(out_path, digests) # no spec_paths key at all
          allow(baseline).to receive(:run_baseline!).and_return("version" => 2, "records" => {}, "times" => {})

          baseline.coverage_map

          expect(baseline.last_refresh).to eq(:cached)
          expect(baseline).not_to have_received(:run_baseline!)
        end
      end

      it "stamps the configured spec_paths onto the cache" do
        Dir.mktmpdir do |root|
          cache_dir = File.join(root, ".active_mutator")
          FileUtils.mkdir_p(cache_dir)
          out_path = File.join(cache_dir, "coverage.json")
          baseline = described_class.new(root: root, spec_paths: ["test"], cache_dir: cache_dir)
          write_cache(out_path, {})
          allow(baseline).to receive(:run_baseline!).and_return("version" => 2, "records" => {}, "times" => {})

          baseline.coverage_map

          expect(JSON.parse(File.read(out_path))["spec_paths"]).to eq(["test"])
        end
      end
    end
  end

  describe "refresh decisions and child failures" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmp = File.realpath(dir)
        FileUtils.mkdir_p(File.join(@tmp, "lib"))
        FileUtils.mkdir_p(File.join(@tmp, "spec"))
        File.write(File.join(@tmp, "lib/a.rb"), "class A; def x = 1; end\n")
        File.write(File.join(@tmp, "spec/a_spec.rb"), "RSpec.describe(A) { it { A.new.x } }\n")
        example.run
      end
    end

    let(:tmp_cache) { File.join(@tmp, ".active_mutator") }
    let(:out_path) { File.join(tmp_cache, "coverage.json") }
    let(:baseline) { described_class.new(root: @tmp, cache_dir: tmp_cache) }
    let(:a_hit) { [[File.join(@tmp, "lib/a.rb"), 1]] }

    def write_cache(digests, version: 2, records: { "./spec/a_spec.rb[1:1]" => a_hit })
      FileUtils.mkdir_p(tmp_cache)
      File.write(out_path, JSON.generate("version" => version, "records" => records,
                                         "times" => records.transform_values { 0.1 },
                                         "digests" => digests, "spec_paths" => ["spec"]))
    end

    # ok: the child's exit; payload: what it leaves at the out path (nil = nothing).
    def fake_child(ok: true, payload: { "version" => 2, "records" => {}, "times" => {} })
      allow(baseline).to receive(:run_rspec) do |path, _targets = []|
        File.write(path, JSON.generate(payload)) if payload
        ok
      end
    end

    it "rebuilds a fresh cache when forced" do
      write_cache(baseline.send(:current_digests))
      fake_child

      baseline.coverage_map(force: true)

      expect(baseline.last_refresh).to eq(:full)
      expect(baseline).to have_received(:run_rspec).with(out_path)
    end

    it "rebuilds rather than delta-refreshing a pre-v2 cache" do
      write_cache(baseline.send(:current_digests).except("spec/a_spec.rb"), version: 1)
      fake_child

      baseline.coverage_map

      expect(baseline.last_refresh).to eq(:full)
      expect(baseline).to have_received(:run_rspec).with(out_path)
    end

    it "fails a full rebuild when the suite fails" do
      fake_child(ok: false)
      expect { baseline.coverage_map }
        .to raise_error(ActiveMutator::BaselineFailed, "baseline suite failed, fix the suite before mutating")
    end

    it "fails a full rebuild when the suite writes no coverage" do
      fake_child(payload: nil)
      expect { baseline.coverage_map }
        .to raise_error(ActiveMutator::BaselineFailed, "baseline produced no coverage output")
    end

    it "fails a full rebuild when the suite stopped early" do
      fake_child(payload: { "version" => 2, "records" => {}, "expected_examples" => 2 })
      expect { baseline.coverage_map }
        .to raise_error(ActiveMutator::BaselineFailed, "baseline aborted early: 0 of 2 examples recorded — " \
                                                       "re-run without interrupting the suite")
    end

    context "with a new spec file (a partial refresh)" do
      before do
        write_cache(baseline.send(:current_digests))
        File.write(File.join(@tmp, "spec/b_spec.rb"), "RSpec.describe(A) { it { A.new.x } }\n")
      end

      it "runs only the new file and removes the partial output" do
        fake_child(payload: { "records" => { "./spec/b_spec.rb[1:1]" => a_hit } })

        baseline.coverage_map

        expect(baseline).to have_received(:run_rspec).with(File.join(tmp_cache, "partial.json"), ["spec/b_spec.rb"])
        expect(File.exist?(File.join(tmp_cache, "partial.json"))).to be(false)
      end

      it "fails when the partial run fails" do
        fake_child(ok: false)
        expect { baseline.coverage_map }
          .to raise_error(ActiveMutator::BaselineFailed, "partial baseline run failed, fix the suite before mutating")
      end

      it "fails when the partial run writes nothing" do
        fake_child(payload: nil)
        expect { baseline.coverage_map }
          .to raise_error(ActiveMutator::BaselineFailed, "partial baseline produced no output")
      end

      it "fails when the partial run stopped early" do
        fake_child(payload: { "records" => {}, "expected_examples" => 1 })
        expect { baseline.coverage_map }
          .to raise_error(ActiveMutator::BaselineFailed, /0 of 1 examples recorded/)
      end
    end

    it "drops a deleted spec file's examples without running a child" do
      File.write(File.join(@tmp, "spec/b_spec.rb"), "RSpec.describe(A) { it { A.new.x } }\n")
      write_cache(baseline.send(:current_digests),
                  records: { "./spec/a_spec.rb[1:1]" => a_hit, "./spec/b_spec.rb[1:1]" => a_hit })
      File.delete(File.join(@tmp, "spec/b_spec.rb"))
      allow(baseline).to receive(:run_rspec)

      map = baseline.coverage_map

      expect(baseline.last_refresh).to eq(:partial)
      expect(baseline).not_to have_received(:run_rspec)
      expect(map.records.keys).to eq(["./spec/a_spec.rb[1:1]"])
    end
  end

  describe "merging a partial run" do
    let(:delta) do
      ActiveMutator::BaselineDelta::Delta.new(
        full: false, rerun_spec_files: ["spec/c_spec.rb"], rerun_example_ids: ["./spec/a_spec.rb[1:1]"],
        drop_example_ids: ["./spec/b_spec.rb[1:1]"], drop_source_files: ["/r/lib/gone.rb"]
      )
    end
    let(:cache) do
      ids = ["./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]", "./spec/c_spec.rb[1:1]",
             "./spec/c_spec.rb_other_spec.rb[1:1]", "./spec/keep_spec.rb[1:1]"]
      { "records" => ids.to_h { |id| [id, [["/r/lib/a.rb", 1], ["/r/lib/gone.rb", 2]]] },
        "times" => ids.to_h { |id| [id, 1.0] } }
    end
    let(:part) do
      { "records" => { "./spec/c_spec.rb[1:2]" => [["/r/lib/a.rb", 3]] }, "times" => { "./spec/c_spec.rb[1:2]" => 2.0 } }
    end

    before { described_class.new(root: "/r").send(:merge_partial!, cache, part, delta) }

    it "drops rerun, dropped, and rerun-file examples and adds the partial run's" do
      kept = ["./spec/c_spec.rb_other_spec.rb[1:1]", "./spec/keep_spec.rb[1:1]", "./spec/c_spec.rb[1:2]"]
      expect(cache["records"].keys).to eq(kept)
      expect(cache["times"]).to eq(kept.to_h { |id| [id, id.end_with?("[1:2]") ? 2.0 : 1.0] })
    end

    it "drops hits in deleted source files" do
      expect(cache["records"]["./spec/keep_spec.rb[1:1]"]).to eq([["/r/lib/a.rb", 1]])
    end
  end
end
