RSpec.describe OpenMutator::CLI do
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
