require "json"
require "open3"
require "fileutils"

RSpec.describe "rails_app end-to-end", :rails_e2e do
  let(:root) { File.expand_path("../fixtures/rails_app", __dir__) }

  after { FileUtils.rm_rf(File.join(root, ".active_mutator")) }

  it "mutates an ActiveRecord model with DB-touching specs" do
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "RAILS_ENV" => "test" },
        "bundle", "exec", "active_mutator", "app", "--format", "json", "--jobs", "1",
        chdir: root
      )
    end

    data = JSON.parse(stdout)
    adult = data.fetch("results").select { |r| r["subject"] == "User#adult?" }
    expect(adult).not_to be_empty, stderr
    boundary = adult.find { |r| r["description"] == "replace `>=` with `>`" }
    expect(boundary["status"]).to eq("killed") # spec covers exactly 18

    # No :error statuses — proves fork + AR reconnect hygiene works:
    expect(data.fetch("results").map { |r| r["status"] }).not_to include("error")
    expect(status.exitstatus).to be_between(0, 1)
  end
end
