require "tmpdir"
require "fileutils"

# Example ids reach a worker in run-priority order (see WorkItem): the
# convention spec first, then the cheapest selected top-level groups. The
# selected set, lane, and budget do not change, only the order.
RSpec.describe ActiveMutator::Runner, "covering group order" do
  around do |ex|
    Dir.mktmpdir do |root|
      @root = File.realpath(root)
      FileUtils.mkdir_p(File.join(@root, "spec/models"))
      FileUtils.mkdir_p(File.join(@root, "spec/requests"))
      FileUtils.mkdir_p(File.join(@root, "app/models"))
      File.write(File.join(@root, "app/models/user.rb"), "class User\n  validates :email, presence: true\n  def name = 1\nend\n")
      File.write(File.join(@root, "spec/models/user_spec.rb"), "RSpec.describe User do\nend\n")
      ex.run
    end
  end

  let(:config) { ActiveMutator::CLI.parse([]).with(root: @root) }
  let(:runner) { described_class.new(config, reporter: instance_double(ActiveMutator::Reporter::Terminal, on_result: nil)) }
  let(:user_file) { File.join(@root, "app/models/user.rb") }

  def subject_for(kind: :instance)
    ActiveMutator::Subject.new(name: "User#name", file: user_file, byte_range: 0...10, line_range: 3..3,
                               constant_scope: "User", kind: kind)
  end

  def mutation_for(subject)
    ActiveMutator::Mutation.new(
      subject: subject,
      edit: ActiveMutator::Edit.new(range: 5...6, replacement: ">=", description: "d", operator: "Literal"),
      original_snippet: ">", line: 3,
      mutated_file_source: "", mutated_def_source: "def x = 1", mutated_def_line: 1
    )
  end

  # records: id => hit on the subject's line; times: id => seconds (nil allowed).
  def map_for(times)
    records = times.keys.to_h { |id| [id, [[user_file, 3]]] }
    ActiveMutator::CoverageMap.new("version" => 2, "records" => records, "times" => times)
  end

  def plan(kind = :instance, **times)
    items, = runner.plan_work([mutation_for(subject_for(kind: kind))], map_for(times))
    items.first
  end

  it "runs the cheapest selected group first and keeps ids sorted inside a group" do
    item = plan("./spec/slow_spec.rb[1:1]" => 9.0, "./spec/fast_spec.rb[1:2]" => 0.1,
                "./spec/fast_spec.rb[1:1]" => 0.1, "./spec/mid_spec.rb[1:1]" => 1.0)
    expect(item.example_ids).to eq(%w[./spec/fast_spec.rb[1:1] ./spec/fast_spec.rb[1:2]
                                      ./spec/mid_spec.rb[1:1] ./spec/slow_spec.rb[1:1]])
  end

  it "ranks top-level groups of one file separately, summing only the selected examples" do
    times = { "./spec/a_spec.rb[1:1]" => 5.0, "./spec/a_spec.rb[2:1]" => 0.1,
              "./spec/b_spec.rb[1:1]" => 1.0 }
    # a's group 1 is slow, its group 2 is cheap; b sits between.
    item = plan(**times)
    expect(item.example_ids).to eq(%w[./spec/a_spec.rb[2:1] ./spec/b_spec.rb[1:1] ./spec/a_spec.rb[1:1]])
  end

  it "sums only the selected examples of a group, not every example of the file" do
    map = map_for("./spec/a_spec.rb[1:1]" => 0.5, "./spec/b_spec.rb[1:1]" => 1.0)
    # An unselected example of a's group is expensive but never selected.
    full = ActiveMutator::CoverageMap.new("version" => 2, "records" => map.records.merge("./spec/a_spec.rb[1:2]" => [["/other.rb", 1]]),
                                          "times" => { "./spec/a_spec.rb[1:1]" => 0.5, "./spec/a_spec.rb[1:2]" => 50.0,
                                                       "./spec/b_spec.rb[1:1]" => 1.0 })
    items, = runner.plan_work([mutation_for(subject_for)], full)
    expect(items.first.example_ids).to eq(%w[./spec/a_spec.rb[1:1] ./spec/b_spec.rb[1:1]])
  end

  it "sums a group's examples" do
    item = plan("./spec/a_spec.rb[1:1]" => 0.6, "./spec/a_spec.rb[1:2]" => 0.6, "./spec/b_spec.rb[1:1]" => 1.0)
    expect(item.example_ids.first).to eq("./spec/b_spec.rb[1:1]")
  end

  it "puts the convention spec first however slow it is, for every subject kind" do
    times = { "./spec/requests/fast_spec.rb[1:1]" => 0.1, "./spec/models/user_spec.rb[1:1]" => 30.0,
              "./spec/requests/other_spec.rb[1:1]" => 0.2 }
    %i[instance class_body].each do |kind|
      item = plan(kind, **times)
      expect(item.example_ids.first).to eq("./spec/models/user_spec.rb[1:1]"), kind.to_s
    end
  end

  it "does not invent a convention group the plan did not select" do
    item = plan("./spec/requests/fast_spec.rb[1:1]" => 0.1, "./spec/requests/slow_spec.rb[1:1]" => 3.0)
    expect(item.example_ids).to eq(%w[./spec/requests/fast_spec.rb[1:1] ./spec/requests/slow_spec.rb[1:1]])
  end

  it "breaks ties by first appearance in the sorted selection" do
    item = plan("./spec/b_spec.rb[1:1]" => 1.0, "./spec/a_spec.rb[1:1]" => 1.0, "./spec/c_spec.rb[1:1]" => 1.0)
    expect(item.example_ids).to eq(%w[./spec/a_spec.rb[1:1] ./spec/b_spec.rb[1:1] ./spec/c_spec.rb[1:1]])
  end

  it "treats nil and missing times as zero cost" do
    item = plan("./spec/a_spec.rb[1:1]" => 1.0, "./spec/nil_spec.rb[1:1]" => nil, "./spec/zero_spec.rb[1:1]" => 0.0)
    expect(item.example_ids).to eq(%w[./spec/nil_spec.rb[1:1] ./spec/zero_spec.rb[1:1] ./spec/a_spec.rb[1:1]])
  end

  it "keeps a malformed id as its own group instead of crashing" do
    item = plan("weird" => 0.0, "./spec/a_spec.rb[1:1]" => 1.0)
    expect(item.example_ids).to match_array(%w[weird ./spec/a_spec.rb[1:1]])
  end

  it "changes only the order: same selected set, lane, timeout, and variable" do
    times = { "./spec/slow_spec.rb[1:1]" => 9.0, "./spec/fast_spec.rb[1:1]" => 0.1,
              "./spec/system/browser_spec.rb[1:1]" => 2.0 }
    map = map_for(times)
    item = runner.plan_work([mutation_for(subject_for)], map).first.first
    selected = map.examples_for(user_file, [3])

    expect(item.example_ids).not_to eq(selected)
    expect(item.example_ids).to match_array(selected)
    expect(item.lane).to eq(:serial)
    expect(item.variable).to eq(map.time_for(selected) * config.timeout_factor)
    expect(item.timeout).to eq(item.variable + config.timeout_floor + config.browser_boot_seconds)
  end

  it "records the ordered ids as the ones phase 1 ran" do
    map = map_for("./spec/slow_spec.rb[1:1]" => 9.0, "./spec/fast_spec.rb[1:1]" => 0.1)
    items, _, phase1 = runner.plan_work([mutation_for(subject_for)], map)
    expect(phase1.fetch(items.first.mutation)).to eq(items.first.example_ids)
  end

  describe "phase 2 escalation" do
    it "orders the escalated examples the same way and keeps the selected set" do
      File.write(File.join(@root, "spec/requests/slow_spec.rb"), "RSpec.describe 'slow' do\n  it { User }\nend\n")
      File.write(File.join(@root, "spec/requests/fast_spec.rb"), "RSpec.describe 'fast' do\n  it { User }\nend\n")
      map = ActiveMutator::CoverageMap.new(
        "version" => 2,
        "records" => { "./spec/models/user_spec.rb[1:1]" => [], "./spec/requests/slow_spec.rb[1:1]" => [],
                       "./spec/requests/fast_spec.rb[1:1]" => [] },
        "times" => { "./spec/requests/slow_spec.rb[1:1]" => 8.0, "./spec/requests/fast_spec.rb[1:1]" => 0.1 }
      )
      mutation = mutation_for(subject_for(kind: :class_body))
      seen = nil
      scheduler = instance_double(ActiveMutator::Scheduler)
      allow(scheduler).to receive(:run) do |items|
        seen = items
        [ActiveMutator::Result.new(mutation: mutation, status: :killed, details: nil)]
      end

      runner.escalate_class_body_survivors(
        [ActiveMutator::Result.new(mutation: mutation, status: :survived, details: nil)], scheduler, map,
        phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
      )

      expect(seen.first.example_ids).to eq(%w[./spec/requests/fast_spec.rb[1:1] ./spec/requests/slow_spec.rb[1:1]])
      expect(seen.first.variable).to eq(map.time_for(seen.first.example_ids) * config.timeout_factor)
    end
  end
end
