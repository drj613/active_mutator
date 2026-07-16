require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe ActiveMutator::ConfigFile do
  let(:root) { Dir.mktmpdir }
  after { FileUtils.remove_entry(root) }

  def write_config(yaml)
    File.write(File.join(root, ".active_mutator.yml"), yaml)
  end

  it "returns an empty hash when no config file exists" do
    expect(described_class.load(root)).to eq({})
  end

  it "loads recognized keys as symbol-keyed options" do
    write_config(<<~YAML)
      jobs: 4
      format: stryker-json
      timeout_factor: 6.5
      timeout_floor: 5
      browser_boot_seconds: 20
      fail_at: 90
      exclude:
        - lib/generated
      serial_patterns:
        - spec/system/
      requires:
        - config/boot.rb
      preload_helper: spec/fast_helper.rb
    YAML
    expect(described_class.load(root)).to eq(
      jobs: 4, format: :stryker_json, timeout_factor: 6.5, timeout_floor: 5.0,
      browser_boot_seconds: 20.0, fail_at: 90.0, exclude: ["lib/generated"],
      serial_patterns: ["spec/system/"], requires: ["config/boot.rb"],
      preload_helper: "spec/fast_helper.rb"
    )
  end

  it "maps preload_helper: false to :none" do
    write_config("preload_helper: false\n")
    expect(described_class.load(root)).to eq(preload_helper: :none)
  end

  it "raises on unknown keys" do
    write_config("job: 4\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /unknown config key: job/)
  end

  it "raises on wrong types" do
    write_config("jobs: fast\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /jobs/)
  end

  it "raises when a number key is not numeric" do
    write_config("fail_at: fast\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /fail_at must be a number/)
  end

  it "lists the valid formats in the format error" do
    write_config("format: xml\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /terminal, json, stryker-json, github/)
  end

  it "raises when a list key is not a list" do
    write_config("exclude: lib/generated\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /exclude must be a list of strings/)
  end

  it "raises when a list key contains non-strings" do
    write_config("exclude:\n  - 42\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /exclude must be a list of strings/)
  end

  it "raises when preload_helper is neither a path nor false" do
    write_config("preload_helper: 3\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /preload_helper must be a path or false/)
  end

  it "raises on an invalid format value" do
    write_config("format: xml\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /format/)
  end

  it "raises when the file is not a YAML mapping" do
    write_config("- just\n- a list\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /mapping/)
  end

  it "raises on unparseable YAML" do
    write_config("jobs: [unclosed\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /\.active_mutator\.yml/)
  end

  it "treats an empty file as no config" do
    write_config("")
    expect(described_class.load(root)).to eq({})
  end
end
