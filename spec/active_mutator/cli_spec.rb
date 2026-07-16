require "tmpdir"

RSpec.describe ActiveMutator::CLI do
  describe ".parse" do
    it "builds a default config" do
      config = described_class.parse([])
      expect(config.paths).to eq([])
      expect(config.since).to be_nil
      expect(config.subject_filter).to be_nil
      expect(config.format).to eq(:terminal)
      expect(config.jobs).to be > 0
      expect(config.force_baseline).to be(false)
      expect(config.root).to eq(Dir.pwd)
    end

    it "parses all flags" do
      config = described_class.parse(
        %w[app lib --since origin/main --subject Foo#bar --jobs 4
           --format json --require ./config/environment --force-baseline
           --timeout-factor 3 --timeout-floor 5]
      )
      expect(config.paths).to eq(%w[app lib])
      expect(config.since).to eq("origin/main")
      expect(config.subject_filter).to eq("Foo#bar")
      expect(config.jobs).to eq(4)
      expect(config.format).to eq(:json)
      expect(config.requires).to eq(["./config/environment"])
      expect(config.force_baseline).to be(true)
      expect(config.timeout_factor).to eq(3.0)
      expect(config.timeout_floor).to eq(5.0)
    end

    it "defaults the v1.1 fields" do
      config = described_class.parse([])
      expect(config.preload_helper).to be_nil
      expect(config.serial_patterns).to eq(["spec/system/", "spec/features/"])
      expect(config.browser_boot_seconds).to eq(15.0)
      expect(config.accept_survivors).to be(false)
    end

    it "parses the v1.1 flags" do
      config = described_class.parse(
        %w[--preload-helper spec/other_helper.rb --serial-pattern spec/browser/
           --browser-boot-seconds 30 --accept-survivors]
      )
      expect(config.preload_helper).to eq("spec/other_helper.rb")
      expect(config.serial_patterns).to eq(["spec/browser/"])
      expect(config.browser_boot_seconds).to eq(30.0)
      expect(config.accept_survivors).to be(true)
    end

    it "parses --no-preload-helper as :none" do
      expect(described_class.parse(%w[--no-preload-helper]).preload_helper).to eq(:none)
    end

    it "parses --format stryker-json" do
      expect(described_class.parse(["--format", "stryker-json"]).format).to eq(:stryker_json)
    end

    it "parses --format github" do
      expect(described_class.parse(["--format", "github"]).format).to eq(:github)
    end

    it "defaults jobs to half the CPU count, minimum 1" do
      allow(Etc).to receive(:nprocessors).and_return(8)
      expect(described_class.parse([]).jobs).to eq(4)
      allow(Etc).to receive(:nprocessors).and_return(1)
      expect(described_class.parse([]).jobs).to eq(1)
    end

    it "documents every option in --help" do
      out = StringIO.new
      orig = $stdout
      $stdout = out
      begin
        expect { described_class.parse(["--help"]) }.to raise_error(SystemExit)
      ensure
        $stdout = orig
      end
      help = out.string
      expect(help).to include("Usage: active_mutator [paths] [options]")
      [
        "Mutate only methods changed since git REF",
        "Mutate uncommitted work (alias for --since HEAD, plus untracked files)",
        "Mutate matching subjects: Foo::Bar#baz, Foo::Bar, Foo::Bar*, Foo::Bar#*",
        "Concurrent workers (default: half the CPU count)",
        "Output format",
        "File to require before mutating (repeatable; adds to config-file requires)",
        "Exit 0 if mutation score >= SCORE even with survivors (default: any survivor fails)",
        "Ignore cached coverage map",
        "Timeout = baseline time * F + floor",
        "Minimum timeout seconds",
        "Spec helper to preload in the parent (default: auto-detect)",
        "Skip spec-helper preload",
        "Covering-path prefix that forces the serial lane (repeatable; replaces defaults on first use)",
        "Extra timeout budget for serial-lane mutants",
        "Record surviving mutants into the acceptance ledger",
        "Skip files matching glob, relative to root (repeatable)",
        "Deterministically sample the first N mutants",
        "Print the planned mutant list as JSON and exit"
      ].each { |desc| expect(help).to include(desc) }
    end

    it "accumulates repeated --serial-pattern flags after replacing the defaults" do
      config = described_class.parse(
        %w[--serial-pattern spec/browser/ --serial-pattern spec/slow/]
      )
      expect(config.serial_patterns).to eq(["spec/browser/", "spec/slow/"])
    end

    it "aliases --changed to --since HEAD" do
      expect(described_class.parse(%w[--changed]).since).to eq("HEAD")
    end

    it "collects repeatable --exclude patterns" do
      config = described_class.parse(["lib", "--exclude", "lib/generated/**", "--exclude", "**/legacy/*"])
      expect(config.exclude).to eq(["lib/generated/**", "**/legacy/*"])
    end

    it "defaults exclude to empty" do
      expect(described_class.parse([]).exclude).to eq([])
    end

    it "parses --max-mutants" do
      expect(described_class.parse(["--max-mutants", "50"]).max_mutants).to eq(50)
    end

    it "defaults max_mutants to nil" do
      expect(described_class.parse([]).max_mutants).to be_nil
    end

    it "parses --debug-plan" do
      expect(described_class.parse(["--debug-plan"]).debug_plan).to be true
    end

    it "defaults debug_plan to false" do
      expect(described_class.parse([]).debug_plan).to be false
    end

    it "parses --fail-at as a float" do
      expect(described_class.parse(["--fail-at", "92.5"]).fail_at).to eq(92.5)
    end

    it "accepts --fail-at at the range boundaries" do
      expect(described_class.parse(["--fail-at", "0"]).fail_at).to eq(0.0)
      expect(described_class.parse(["--fail-at", "100"]).fail_at).to eq(100.0)
    end

    it "rejects --fail-at outside 0..100" do
      expect { described_class.parse(["--fail-at", "101"]) }
        .to raise_error(OptionParser::InvalidArgument, /must be within 0\.\.100/)
      expect { described_class.parse(["--fail-at", "-1"]) }
        .to raise_error(OptionParser::InvalidArgument, /must be within 0\.\.100/)
    end

    it "defaults fail_at to nil" do
      expect(described_class.parse([]).fail_at).to be_nil
    end
  end

  describe "config file layering" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    it "seeds defaults from .active_mutator.yml" do
      File.write(".active_mutator.yml", "jobs: 3\nfail_at: 85\n")
      config = described_class.parse([])
      expect(config.jobs).to eq(3)
      expect(config.fail_at).to eq(85.0)
    end

    it "lets CLI flags override file values" do
      File.write(".active_mutator.yml", "jobs: 3\nformat: json\n")
      config = described_class.parse(["--jobs", "7", "--format", "terminal"])
      expect(config.jobs).to eq(7)
      expect(config.format).to eq(:terminal)
    end

    it "lets --serial-pattern replace file-provided serial_patterns" do
      File.write(".active_mutator.yml", "serial_patterns:\n  - spec/system/\n")
      config = described_class.parse(["--serial-pattern", "spec/browser/"])
      expect(config.serial_patterns).to eq(["spec/browser/"])
    end

    it "surfaces config file errors as exit code 2 via run" do
      File.write(".active_mutator.yml", "bogus_key: 1\n")
      expect { @code = described_class.run([]) }.to output(/unknown config key/).to_stderr
      expect(@code).to eq(2)
    end

    it "accumulates --require flags onto file-provided requires" do
      File.write(".active_mutator.yml", "requires:\n  - a.rb\n")
      config = described_class.parse(["--require", "b.rb"])
      expect(config.requires).to eq(["a.rb", "b.rb"])
    end

    it "works with no config file present" do
      expect(described_class.parse([]).fail_at).to be_nil
    end
  end

  describe ".run" do
    it "returns exit code 2 with a message on unknown flags" do
      code = nil
      expect { code = described_class.run(["--nope"]) }
        .to output(/invalid option/).to_stderr
      expect(code).to eq(2)
    end
  end
end
