require "tmpdir"

RSpec.describe ActiveMutator::RunInputs do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  def make_input(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def fingerprint(*flags)
    described_class.new(ActiveMutator::CLI.parse(flags)).setup
  end

  %w[.rspec Gemfile Gemfile.lock spec/.case.json spec/cases.json spec/support/hooks.rb config/environment.rb db/schema.rb db/structure.sql].each do |path|
    it "invalidates the shared setup when #{path} changes or is removed" do
      initial = fingerprint
      make_input(path, "# first")
      first = fingerprint
      expect(first).not_to eq(initial)

      make_input(path, "# second")
      expect(fingerprint).not_to eq(first)
      File.unlink(path)
      expect(fingerprint).to eq(initial)
    end
  end

  it "fingerprints extensionless CLI requires by the file Ruby loads" do
    make_input("mode.rb", "LIMIT = 10")
    original = fingerprint("--require", "mode")
    make_input("mode.rb", "LIMIT = 5")

    expect(fingerprint("--require", "mode")).not_to eq(original)
  end

  it "fingerprints files explicitly required by local RSpec options" do
    make_input(".rspec-local", "--require ./mode.rb")
    make_input("mode.rb", "LIMIT = 10")
    original = fingerprint
    make_input("mode.rb", "LIMIT = 5")

    expect(fingerprint).not_to eq(original)
    File.unlink(".rspec-local")
    expect(fingerprint).not_to eq(original)
  end

  it "leaves ordinary spec contents to per-mutant invalidation" do
    original = fingerprint
    make_input("spec/counter_spec.rb", "example")

    expect(fingerprint).to eq(original)
  end
  [
    ["--require mode", "lib/mode.rb"],
    ["--require mode_spec", "spec/mode_spec.rb"],
    ["--default-path test --require mode", "test/mode.rb"],
    ["-I helpers --require mode", "helpers/mode.rb"]
  ].each do |options, path|
    it "tracks #{path} when RSpec searches for a required file" do
      make_input(".rspec", options)
      make_input(path, "LIMIT = 10")
      original = fingerprint
      make_input(path, "LIMIT = 5")

      expect(fingerprint).not_to eq(original)
    end
  end

  it "tracks RSpec options outside the checkout" do
    config_dir = File.expand_path("user-config")
    home_options = File.expand_path("user-options")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("XDG_CONFIG_HOME", anything).and_return(config_dir)
    allow(File).to receive(:expand_path).and_call_original
    allow(File).to receive(:expand_path).with("~/.rspec").and_return(home_options)
    original = fingerprint
    make_input(home_options, "# personal RSpec options")
    personal = fingerprint
    expect(personal).not_to eq(original)
    make_input(File.join(config_dir, "rspec/options"), "--order defined")
    expect(fingerprint).not_to eq(personal)
  end

  it "tracks config, source, and spec changes independently after taking a snapshot" do
    make_input("lib/counter.rb", "class Counter; def count = 2; end")
    make_input("lib/other.rb", "class Other; def count = 3; end")
    make_input("spec/counter_spec.rb", "# first spec")
    make_input("spec/other_spec.rb", "# second spec")
    paths = %w[lib/counter.rb lib/other.rb].map { |file| File.expand_path(file) }
    inputs = described_class.new(ActiveMutator::CLI.parse([]))
    inputs.analyze(paths.flat_map { |file| ActiveMutator::SubjectFinder.call(file) })
    digests = %w[spec/counter_spec.rb spec/other_spec.rb].to_h do |file|
      [file, Digest::SHA256.file(file).hexdigest]
    end
    map = ActiveMutator::CoverageMap.new("digests" => digests)
    expect(inputs.stable?(map)).to be(true)

    ["lib/counter.rb", "spec/counter_spec.rb"].each do |path|
      original = File.read(path)
      File.write(path, original + "\n# edit")
      expect(inputs.stable?(map)).to be(false)
      File.write(path, original)
    end
    make_input("spec/cases.json", "{}")
    expect(inputs.stable?(map)).to be(false)
  end

  it "excludes files outside the configured spec directory" do
    inputs = described_class.new(ActiveMutator::CLI.parse(%w[--spec-path test]))
    map = ActiveMutator::CoverageMap.new("digests" => { "test/a_spec.rb" => "test", "testing/b.rb" => "outside" })
    expect(inputs.spec_digests(map)).to eq("test/a_spec.rb" => "test")
  end
  it "requires RSpec core before inspecting options" do
    inputs = described_class.allocate
    expect(inputs).to receive(:require).with("rspec/core").and_call_original

    inputs.send(:initialize, ActiveMutator::CLI.parse([]))
  end

  it "keeps fingerprint implementation private" do
    inputs = described_class.new(ActiveMutator::CLI.parse([]))
    expect(inputs).not_to respond_to(:setup_fingerprint)
    expect(inputs).not_to respond_to(:require_files)
  end

  it "tracks local RSpec options even when their require list stays the same" do
    make_input(".rspec-local", "--order defined")
    original = fingerprint
    make_input(".rspec-local", "--order rand")
    expect(fingerprint).not_to eq(original)
  end

  it "ignores load-path lookalikes of explicit RSpec require paths" do
    make_input(".rspec", "-I helpers --require ./mode.rb")
    make_input("mode.rb", "MODE = 1")
    make_input("helpers/mode.rb", "MODE = 2")
    original = fingerprint
    make_input("helpers/mode.rb", "MODE = 3")
    expect(fingerprint).to eq(original)
  end

  it "tracks the default XDG options file" do
    config_dir = File.expand_path("user-config")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("XDG_CONFIG_HOME", anything) { |_key, default| default }
    allow(File).to receive(:expand_path).and_call_original
    allow(File).to receive(:expand_path).with("~/.config").and_return(config_dir)
    original = fingerprint
    make_input(File.join(config_dir, "rspec/options"), "--order defined")
    expect(fingerprint).not_to eq(original)
  end

  it "tracks runtime RSpec options" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SPEC_OPTS").and_return(nil)
    original = fingerprint
    allow(ENV).to receive(:[]).with("SPEC_OPTS").and_return("--order rand")
    expect(fingerprint).not_to eq(original)
  end

  it "uses the worker's default Rails environment and tracks overrides" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("RAILS_ENV", anything) { |_key, default| default }
    default = fingerprint
    allow(ENV).to receive(:fetch).with("RAILS_ENV", anything).and_return("test")
    expect(fingerprint).to eq(default)
    allow(ENV).to receive(:fetch).with("RAILS_ENV", anything).and_return("custom")
    expect(fingerprint).not_to eq(default)
  end

  it "tracks edits to the installed gem even if its version field stays the same" do
    file = File.expand_path("../../lib/active_mutator/worker.rb", __dir__)
    original = fingerprint
    allow(Digest::SHA256).to receive(:file).and_call_original
    allow(Digest::SHA256).to receive(:file).with(file).and_return(Digest::SHA256.new.update("changed"))
    expect(fingerprint).not_to eq(original)
  end
  it "keeps the setup fingerprint when file enumeration order changes" do
    make_input("config/a.rb", "A = 1")
    make_input("config/b.rb", "B = 2")
    original = fingerprint
    allow(Dir).to receive(:glob).and_wrap_original do |glob, pattern, *args, **options|
      paths = glob.call(pattern, *args, **options)
      %w[config/**/* **/*.rb].include?(pattern) ? paths.reverse : paths
    end

    expect(fingerprint).to eq(original)
  end
end
