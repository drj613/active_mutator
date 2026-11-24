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

  %w[spec/cases.json spec/support/hooks.rb config/environment.rb db/schema.rb db/structure.sql].each do |path|
    it "invalidates the shared setup when #{path} changes or is removed" do
      initial = fingerprint
      make_input(path, "first")
      first = fingerprint
      expect(first).not_to eq(initial)

      make_input(path, "second")
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
end
