require "json"
require "open3"

RSpec.describe "dev-loop end-to-end", :e2e do
  def run_mutator(root, *args)
    stdout, stderr, status = Open3.capture3(
      { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
      "bundle", "exec", "active_mutator", *args, chdir: root
    )
    [stdout, stderr, status]
  end

  it "accepts survivors via the ledger and exits 0 on the next run" do
    with_fixture_copy do |root|
      out, err, status = run_mutator(root, "lib", "--format", "json")
      expect(status.exitstatus).to eq(1), err
      expect(JSON.parse(out)["counts"]["survived"]).to eq(2)

      _, err2, status2 = run_mutator(root, "lib", "--format", "json", "--accept-survivors")
      expect(status2.exitstatus).to eq(1), err2 # acceptance takes effect NEXT run
      ledger = JSON.parse(File.read(File.join(root, ".active_mutator_accepted.json")))
      expect(ledger.size).to eq(2)

      out3, err3, status3 = run_mutator(root, "lib", "--format", "json")
      data = JSON.parse(out3)
      expect(data["counts"]["accepted"]).to eq(2)
      expect(data["counts"]["survived"]).to eq(0)
      expect(data["exit_reason"]).to eq("clean")
      expect(status3.exitstatus).to eq(0), err3
    end
  end

  it "scopes to uncommitted work with --changed, including untracked files" do
    with_fixture_copy do |root|
      system("git", "init", "-q", chdir: root, out: :err)
      system("git", "-C", root, "add", "-A", out: :err)
      system("git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-qm", "base", out: :err)

      # Untracked new file with a method and a spec that half-tests it
      File.write(File.join(root, "lib", "greeter.rb"), <<~RUBY)
        class Greeter
          def shout(name)
            name.to_s.upcase + "!"
          end
        end
      RUBY
      File.write(File.join(root, "spec", "greeter_spec.rb"), <<~RUBY)
        require_relative "../lib/greeter"
        RSpec.describe Greeter do
          it "shouts" do
            expect(Greeter.new.shout("hi")).to start_with("HI")
          end
        end
      RUBY

      out, err, status = run_mutator(root, "lib", "--changed", "--format", "json")
      data = JSON.parse(out)
      subjects = data["results"].map { |r| r["subject"] }.uniq
      expect(subjects).to eq(["Greeter#shout"]), err   # committed Calculator methods NOT mutated
      expect(data["results"].map { |r| r["status"] }).to include("survived") # `+ "!"` unasserted
      expect(status.exitstatus).to eq(1)
    end
  end

  describe "--changed with an empty plan" do
    def commit_all(root)
      system("git", "init", "-q", chdir: root, out: :err)
      system("git", "-C", root, "add", "-A", out: :err)
      system("git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-qm", "base", out: :err)
    end

    it "forgives docs-and-spec-only changes with --allow-empty and prints the zero block" do
      with_fixture_copy do |root|
        commit_all(root)
        File.write(File.join(root, "README.md"), "docs only\n")
        File.write(File.join(root, "spec", "extra_spec.rb"), "RSpec.describe('extra') { it { expect(1).to eq(1) } }\n")

        out, err, status = run_mutator(root, "lib", "--changed", "--allow-empty")
        expect(status.exitstatus).to eq(0), err
        expect(out).to include("killed: 0", "skipped: 0", "invalid (discarded): 0")
        expect(out).not_to include("Mutation score")
        expect(err).to include("no mutants planned")
        expect(File).not_to exist(File.join(root, ".active_mutator", "baseline.json"))
      end
    end

    it "exits 1 naming an untracked source file that produced no mutants" do
      with_fixture_copy do |root|
        commit_all(root)
        File.write(File.join(root, "lib", "empty_thing.rb"), "# nothing mutable here\nclass EmptyThing\nend\n")

        out, err, status = run_mutator(root, "lib", "--changed", "--allow-empty")
        expect(status.exitstatus).to eq(1), err
        expect(out).to include("killed: 0")
        expect(err).to include("Changed: lib/empty_thing.rb")
      end
    end
  end
end
