require "tmpdir"

RSpec.describe ActiveMutator::Runner do
  def mutation_for(file, kind: :class_body, name: "User (class body)")
    subject = ActiveMutator::Subject.new(
      name: name, file: file,
      byte_range: 0...30, line_range: 1..3,
      constant_scope: "User", kind: kind, sclass: false
    )
    ActiveMutator::Mutation.new(
      subject: subject,
      edit: ActiveMutator::Edit.new(range: 14...18, replacement: "false",
                                    description: "replace `true` with `false`", operator: "Literal"),
      original_snippet: "true", line: 2,
      mutated_file_source: "x", mutated_def_source: "x", mutated_def_line: 1
    )
  end

  def result(mutation, status, details: nil)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: details)
  end

  around do |ex|
    Dir.mktmpdir do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "app/models"))
      FileUtils.mkdir_p(File.join(root, "spec/models"))
      FileUtils.mkdir_p(File.join(root, "spec/requests"))
      File.write(File.join(root, "app/models/user.rb"), "class User\n  validates :email, presence: true\nend\n")
      File.write(File.join(root, "spec/models/user_spec.rb"), "RSpec.describe User do\nend\n")
      File.write(File.join(root, "spec/requests/signup_spec.rb"), "RSpec.describe \"signup\" do\n  it { User }\nend\n")
      ex.run
    end
  end

  let(:config) { ActiveMutator::CLI.parse([]).with(root: @root) }
  let(:reporter) { instance_double(ActiveMutator::Reporter::Terminal, on_result: nil) }
  let(:runner) { described_class.new(config, reporter: reporter) }
  let(:user_file) { File.join(@root, "app/models/user.rb") }

  it "re-runs class-body survivors against referencing spec files and takes the escalated verdict" do
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    # Phase 1 covered only the convention file:
    allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb")
                                                  .and_return(["./spec/models/user_spec.rb[1:1]"])
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/signup_spec.rb")
                                                  .and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).to receive(:run) do |items|
      expect(items.size).to eq(1)
      expect(items.first.example_ids).to eq(["./spec/requests/signup_spec.rb[1:1]"])
      [result(mutation, :killed)]
    end

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map,
      phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
    )
    expect(results.map(&:status)).to eq([:killed])
    # A killed escalation is a plain kill, never annotated as a survivor.
    expect(results.first.details).to be_nil
  end

  it "annotates a mutant that survives escalation" do
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/signup_spec.rb")
                                                  .and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler, run: [result(mutation, :survived)])

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map,
      phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
    )
    expect(results.first.status).to eq(:survived)
    expect(results.first.details).to eq("escalated (+1 spec files)")
  end

  it "counts distinct spec files and passes deduped, sorted example ids to the scheduler" do
    File.write(File.join(@root, "spec/requests/b_spec.rb"), "RSpec.describe(\"b\") { it { User } }\n")
    File.write(File.join(@root, "spec/requests/c_spec.rb"), "RSpec.describe(\"c\") { it { User } }\n")
    File.write(File.join(@root, "spec/requests/none_spec.rb"), "RSpec.describe(\"none\") { it { 1 } }\n")
    File.delete(File.join(@root, "spec/requests/signup_spec.rb"))
    File.delete(File.join(@root, "spec/models/user_spec.rb"))
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/b_spec.rb")
                                                  .and_return(["./spec/requests/b_spec.rb[1:2]",
                                                               "./spec/requests/b_spec.rb[1:1]"])
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/c_spec.rb")
                                                  .and_return(["./spec/requests/c_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).to receive(:run) do |items|
      expect(items.first.example_ids).to eq(["./spec/requests/b_spec.rb[1:1]",
                                              "./spec/requests/b_spec.rb[1:2]",
                                              "./spec/requests/c_spec.rb[1:1]"])
      [result(mutation, :survived)]
    end

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map, phase1_ids: {}
    )
    expect(results.first.details).to eq("escalated (+2 spec files)")
  end

  it "leaves the survivor untouched when no extra spec files reference the constant" do
    File.write(File.join(@root, "spec/requests/signup_spec.rb"), "RSpec.describe \"signup\" do\nend\n")
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).not_to receive(:run)

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map,
      phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
    )
    expect(results.first.status).to eq(:survived)
    expect(results.first.details).to be_nil
  end

  it "returns no escalation when the subject file defines no constants" do
    File.write(user_file, "x = 1\n")
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).not_to receive(:run)

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map, phase1_ids: {}
    )
    expect(results.first.status).to eq(:survived)
    expect(results.first.details).to be_nil
  end

  it "escapes regex metachars in constant names (no false matches on the bare text)" do
    # `class (a)::Baz` yields the raw slice "(a)::Baz"; unescaped it would match
    # the literal text "a::Baz" and wrongly escalate a spec that only mentions
    # the paren-less form.
    File.write(user_file, "class (a)::Baz; def x; 1; end; end\n")
    File.write(File.join(@root, "spec/requests/signup_spec.rb"), "RSpec.describe a::Baz do; end\n")
    File.delete(File.join(@root, "spec/models/user_spec.rb"))
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for_spec_file)
      .with("spec/requests/signup_spec.rb").and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).not_to receive(:run)

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map, phase1_ids: {}
    )
    expect(results.first.status).to eq(:survived)
  end

  it "matches any of several defined constants (alternation, not concatenation)" do
    File.write(user_file, "class Foo; end\nclass Bar; end\n")
    File.write(File.join(@root, "spec/requests/signup_spec.rb"), "RSpec.describe Foo do; end\n")
    File.delete(File.join(@root, "spec/models/user_spec.rb"))
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for_spec_file)
      .with("spec/requests/signup_spec.rb").and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).to receive(:run).and_return([result(mutation, :killed)])

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map, phase1_ids: {}
    )
    expect(results.first.status).to eq(:killed)
  end

  it "does not escalate a class-body result that phase 1 already killed" do
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).not_to receive(:run)

    results = runner.escalate_class_body_survivors([result(mutation, :killed)], scheduler, map, phase1_ids: {})
    expect(results.map(&:status)).to eq([:killed])
  end

  it "does not touch non-class-body survivors" do
    def_mutation = mutation_for(user_file, kind: :instance, name: "User#x")
    map = instance_double(ActiveMutator::CoverageMap)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).not_to receive(:run)

    results = runner.escalate_class_body_survivors([result(def_mutation, :survived)], scheduler, map, phase1_ids: {})
    expect(results.map(&:status)).to eq([:survived])
  end

  it "leaves unrelated results untouched while escalating a class-body survivor" do
    cb = mutation_for(user_file)
    other = mutation_for(user_file, kind: :instance, name: "User#x")
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb")
                                                  .and_return([])
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/signup_spec.rb")
                                                  .and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler, run: [result(cb, :killed)])

    results = runner.escalate_class_body_survivors(
      [result(cb, :survived), result(other, :survived, details: "keep me")],
      scheduler, map, phase1_ids: {}
    )
    by_mutation = results.to_h { |r| [r.mutation, r] }
    expect(by_mutation[cb].status).to eq(:killed)
    expect(by_mutation[other].status).to eq(:survived)
    expect(by_mutation[other].details).to eq("keep me")
  end

  it "relativizes spec paths correctly even when the configured root has a trailing slash" do
    slash_runner = described_class.new(config.with(root: "#{@root}/"), reporter: reporter)
    mutation = mutation_for(user_file)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb")
                                                  .and_return(["./spec/models/user_spec.rb[1:1]"])
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/signup_spec.rb")
                                                  .and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).to receive(:run) do |items|
      expect(items.first.example_ids).to eq(["./spec/requests/signup_spec.rb[1:1]"])
      [result(mutation, :killed)]
    end

    results = slash_runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map,
      phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
    )
    expect(results.map(&:status)).to eq([:killed])
  end

  describe "#call wiring" do
    let(:map) { instance_double(ActiveMutator::CoverageMap) }
    let(:recording_reporter) do
      Class.new do
        attr_reader :summary_results
        def on_result(_result) = nil
        def summary(results, invalid_count:) = (@summary_results = results)
      end.new
    end

    around do |ex|
      saved = ENV.to_h.slice("ACTIVE_MUTATOR", "RAILS_ENV")
      ex.run
    ensure
      ENV.delete("ACTIVE_MUTATOR")
      ENV.delete("RAILS_ENV")
      saved.each { |k, v| ENV[k] = v }
    end

    it "escalates class-body survivors after the scheduler run, changing the final verdict" do
      mutation = mutation_for(user_file)
      runner = described_class.new(config, reporter: recording_reporter)
      allow(runner).to receive(:discover_subjects).and_return([mutation.subject])
      analysis = ActiveMutator::Analysis.new(mutations: [mutation], invalid_count: 0)
      allow(ActiveMutator::Engine).to receive(:new)
        .and_return(instance_double(ActiveMutator::Engine, analyze: analysis))
      allow(ActiveMutator::Baseline).to receive(:new)
        .and_return(instance_double(ActiveMutator::Baseline, coverage_map: map))
      allow(map).to receive(:examples_covering_file).and_return([])
      allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb")
                                                    .and_return(["./spec/models/user_spec.rb[1:1]"])
      allow(map).to receive(:examples_for_spec_file).with("spec/requests/signup_spec.rb")
                                                    .and_return(["./spec/requests/signup_spec.rb[1:1]"])
      allow(map).to receive(:time_for).and_return(0.1)
      scheduler = instance_double(ActiveMutator::Scheduler)
      # Phase 1 survives; escalation against signup_spec kills it.
      allow(scheduler).to receive(:run).and_return([result(mutation, :survived)], [result(mutation, :killed)])
      allow(ActiveMutator::Scheduler).to receive(:new).and_return(scheduler)

      code = runner.call

      expect(recording_reporter.summary_results.map(&:status)).to eq([:killed])
      expect(code).to eq(0)
    end
  end
end
