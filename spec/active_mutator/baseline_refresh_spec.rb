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

  it "picks up a newly-covering example from an unchanged spec file (#11)" do
    with_fixture_copy do |root|
      # Two spec files. widget_spec covers Widget#size. helper_spec references
      # Widget textually but takes an early-return path that never executes
      # lib/widget.rb, so it owns no coverage of it.
      File.write(File.join(root, "lib/widget.rb"), <<~RUBY)
        class Widget
          def size
            1
          end
        end
      RUBY
      File.write(File.join(root, "spec/widget_spec.rb"), <<~RUBY)
        require_relative "../lib/widget"
        RSpec.describe Widget do
          it("has a size") { expect(Widget.new.size).to eq(1) }
        end
      RUBY
      File.write(File.join(root, "spec/helper_spec.rb"), <<~RUBY)
        RSpec.describe "helper" do
          it "only touches Widget when the flag file exists" do
            if File.exist?(File.expand_path("../flag", __dir__))
              require_relative "../lib/widget"
              expect(Widget.new.size).to eq(2)
            else
              expect(true).to be(true)
            end
          end
        end
      RUBY

      widget = File.join(root, "lib/widget.rb")
      baseline = ActiveMutator::Baseline.new(root: root)
      first = baseline.coverage_map
      expect(first.examples_covering_file(widget).map { |id| id[%r{spec/\w+_spec}] }.uniq)
        .to eq(["spec/widget_spec"])

      # Edit ONLY the source file; simultaneously the helper example starts
      # covering it (flag file flips its branch). helper_spec.rb is unchanged.
      File.write(File.join(root, "flag"), "")
      File.write(File.join(root, "lib/widget.rb"), <<~RUBY)
        class Widget
          def size
            2
          end
        end
      RUBY
      File.write(File.join(root, "spec/widget_spec.rb"), <<~RUBY)
        require_relative "../lib/widget"
        RSpec.describe Widget do
          it("has a size") { expect(Widget.new.size).to eq(2) }
        end
      RUBY

      refreshed = baseline.coverage_map
      expect(baseline.last_refresh).to eq(:partial)
      covering = refreshed.examples_covering_file(widget)
      expect(covering.map { |id| id[%r{spec/\w+_spec}] }.uniq.sort)
        .to eq(["spec/helper_spec", "spec/widget_spec"])
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
