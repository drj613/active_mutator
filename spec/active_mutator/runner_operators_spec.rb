require "tmpdir"
require "fileutils"

RSpec.describe ActiveMutator::Runner, "#load_operators" do
  around do |ex|
    Dir.mktmpdir { |dir| @root = dir; ex.run }
  end

  # Loading an operator file subclasses Operators::Base, which self-registers
  # into REGISTRY. Undo that so the class does not leak into other examples.
  after { ActiveMutator::Operators::Base::REGISTRY.reject! { |k| k.name == "LoadedNilGuard" } }

  def config_with(operators)
    ActiveMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: @root, preload_helper: nil, serial_patterns: [],
      browser_boot_seconds: 15.0, accept_survivors: false, exclude: [],
      max_mutants: nil, debug_plan: false, fail_at: nil, adaptive_timeout: true,
      operators: operators, class_level: true, class_level_closure_cap: 10
    )
  end

  it "loads operator files, self-registering the subclass" do
    File.write(File.join(@root, "op.rb"), <<~RUBY)
      class LoadedNilGuard < ActiveMutator::Operators::Base
        def edits(node) = []
      end
    RUBY

    runner = described_class.new(config_with(["op.rb"]))
    runner.send(:load_operators)

    expect(ActiveMutator::Operators::Base.all.map { |o| o.class.name })
      .to include("LoadedNilGuard")
  end

  it "raises a friendly Error for a missing operator file" do
    runner = described_class.new(config_with(["nope.rb"]))
    expect { runner.send(:load_operators) }
      .to raise_error(ActiveMutator::Error, /operator file not loadable: nope\.rb/)
  end

  it "raises a friendly Error for an operator file that fails to parse" do
    File.write(File.join(@root, "bad.rb"), "class Broken <\n")
    runner = described_class.new(config_with(["bad.rb"]))
    expect { runner.send(:load_operators) }
      .to raise_error(ActiveMutator::Error, /operator file not loadable: bad\.rb/)
  end
end
