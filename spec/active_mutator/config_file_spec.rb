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

  it "maps the operators key to operator_paths" do
    write_config("operators:\n  - ops/custom.rb\n")
    expect(described_class.load(root)).to eq(operator_paths: ["ops/custom.rb"])
  end

  it "accepts adaptive_timeout: false" do
    write_config("adaptive_timeout: false\n")
    expect(described_class.load(root)[:adaptive_timeout]).to be false
  end

  it "accepts adaptive_timeout: true" do
    write_config("adaptive_timeout: true\n")
    expect(described_class.load(root)[:adaptive_timeout]).to be true
  end

  it "rejects a non-boolean adaptive_timeout" do
    write_config("adaptive_timeout: nope\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /adaptive_timeout must be true or false/)
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
    write_config("timeout_factor: fast\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /timeout_factor must be a number/)
  end

  it "raises when fail_at is not numeric" do
    write_config("fail_at: fast\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /fail_at must be a number/)
  end

  it "raises when fail_at is outside 0..100" do
    write_config("fail_at: 150\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /fail_at must be within 0\.\.100/)
    write_config("fail_at: 100.5\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /fail_at must be within 0\.\.100/)
    write_config("fail_at: -0.5\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /fail_at must be within 0\.\.100/)
  end

  it "accepts fail_at at the range boundaries" do
    write_config("fail_at: 0\n")
    expect(described_class.load(root)).to eq(fail_at: 0.0)
    write_config("fail_at: 100\n")
    expect(described_class.load(root)).to eq(fail_at: 100.0)
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

  it "raises on date-like scalars instead of crashing" do
    write_config("fail_at: 2020-01-01\n")
    expect { described_class.load(root) }
      .to raise_error(ActiveMutator::Error, /\.active_mutator\.yml/)
  end

  it "allows YAML anchors and aliases" do
    write_config("serial_patterns: &sp [\"spec/system/\"]\nexclude: *sp\n")
    expect(described_class.load(root))
      .to eq(serial_patterns: ["spec/system/"], exclude: ["spec/system/"])
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

  it "raises on an unhandled validator (internal bug guard)" do
    expect { described_class.coerce("x", :bogus, 1) }
      .to raise_error(ActiveMutator::Error, /unhandled validator bogus/)
  end

  it "treats an empty file as no config" do
    write_config("")
    expect(described_class.load(root)).to eq({})
  end

  it "accepts class_level and class_level_closure_cap" do
    write_config("class_level: false\nclass_level_closure_cap: 25\n")
    expect(described_class.load(root)).to eq(class_level: false, class_level_closure_cap: 25)
  end

  it "rejects a non-boolean class_level" do
    write_config("class_level: 1\n")
    expect { described_class.load(root) }.to raise_error(ActiveMutator::Error, /class_level must be true or false/)
  end
end
