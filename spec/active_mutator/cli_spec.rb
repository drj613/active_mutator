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

    it "aliases --changed to --since HEAD" do
      expect(described_class.parse(%w[--changed]).since).to eq("HEAD")
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
