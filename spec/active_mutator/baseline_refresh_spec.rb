require "json"

RSpec.describe "Baseline delta refresh", :integration do
  it "refreshes surgically when a spec file changes, keeping unrelated records" do
    with_fixture_copy do |root|
      baseline = ActiveMutator::Baseline.new(root: root)
      map1 = baseline.coverage_map
      calculator = File.join(root, "lib/calculator.rb")
      original_examples = map1.examples_for(calculator, 3..3)
      expect(original_examples).not_to be_empty

      # Add a new spec file covering untested_helper (line 16)
      File.write(File.join(root, "spec", "helper_spec.rb"), <<~RUBY)
        RSpec.describe Calculator do
          it "covers the helper" do
            expect(Calculator.new.untested_helper).to eq(42)
          end
        end
      RUBY

      map2 = baseline.coverage_map
      expect(baseline.last_refresh).to eq(:partial)
      expect(map2.examples_for(calculator, 16..16)).not_to be_empty  # new coverage present
      expect(map2.examples_for(calculator, 3..3)).to eq(original_examples) # untouched records kept
    end
  end

  it "falls back to full re-run when a support file appears" do
    with_fixture_copy do |root|
      baseline = ActiveMutator::Baseline.new(root: root)
      baseline.coverage_map
      FileUtils.mkdir_p(File.join(root, "spec", "support"))
      File.write(File.join(root, "spec", "support", "noise.rb"), "# support change\n")
      baseline.coverage_map
      expect(baseline.last_refresh).to eq(:full)
      expect(ActiveMutator::CoverageMap.load(File.join(root, ".active_mutator", "coverage.json")).version).to eq(2)
    end
  end
end
