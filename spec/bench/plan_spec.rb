require "json"
require "tmpdir"
require_relative "../../bench/lib/bench/plan"

RSpec.describe Bench::Plan do
  def write_targets(dir, data)
    path = File.join(dir, "targets.json")
    File.write(path, JSON.generate(data))
    path
  end

  it "expands the jobs x timeout_factor matrix into named cells" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "tiny", "type" => "path", "path" => "spec/fixtures/tiny_project",
          "paths" => ["lib"], "matrix" => { "jobs" => [1, 2], "timeout_factor" => [8.0] } }
      ])
      cells = described_class.load(path).cells
      expect(cells.map(&:id)).to eq(["tiny-jobs1-tf8.0", "tiny-jobs2-tf8.0"])
      expect(cells.first.argv).to eq(
        ["lib", "--jobs", "1", "--timeout-factor", "8.0",
         "--no-adaptive-timeout", "--format", "stryker-json"]
      )
      expect(cells.first.target_name).to eq("tiny")
      expect(cells.first.path).to eq("spec/fixtures/tiny_project")
    end
  end

  it "defaults the matrix to a single cell with no extra flags" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "tiny", "type" => "path", "path" => "spec/fixtures/tiny_project",
          "paths" => ["lib"] }
      ])
      cells = described_class.load(path).cells
      expect(cells.map(&:id)).to eq(["tiny-default"])
      expect(cells.first.argv).to eq(["lib", "--no-adaptive-timeout", "--format", "stryker-json"])
    end
  end

  it "lets a matrix row opt back in to adaptive timeouts as a boolean flag" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "tiny", "type" => "path", "path" => "spec/fixtures/tiny_project",
          "paths" => ["lib"], "matrix" => { "adaptive_timeout" => [true, false] } }
      ])
      argvs = described_class.load(path).cells.map(&:argv)
      expect(argvs[0]).to eq(["lib", "--adaptive-timeout", "--format", "stryker-json"])
      expect(argvs[1]).to eq(["lib", "--no-adaptive-timeout", "--format", "stryker-json"])
    end
  end

  it "rejects unknown target types" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [{ "name" => "x", "type" => "svn" }])
      expect { described_class.load(path) }.to raise_error(/unknown target type/)
    end
  end

  it "carries git url and sha for git targets" do
    Dir.mktmpdir do |dir|
      path = write_targets(dir, "targets" => [
        { "name" => "g", "type" => "git", "url" => "https://example.com/g.git",
          "sha" => "abc123", "paths" => ["lib"] }
      ])
      cells = described_class.load(path).cells
      expect(cells.first.git_url).to eq("https://example.com/g.git")
      expect(cells.first.git_sha).to eq("abc123")
      expect(cells.first.path).to eq("bench/.cache/g")
    end
  end
end
