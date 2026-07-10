require "json"
require "stringio"

RSpec.describe OpenMutator::Worker do
  let(:writer) { StringIO.new }
  let(:mutation) { instance_double(OpenMutator::Mutation) }
  let(:rspec_runner) { instance_double(RSpec::Core::Runner) }

  def emitted
    JSON.parse(writer.string)
  end

  def run_worker
    described_class.new(mutation, ["spec/x_spec.rb[1:1]"], writer).run
  end

  before do
    allow(RSpec::Core::Runner).to receive(:new).and_return(rspec_runner)
    allow(rspec_runner).to receive(:setup)
    allow(RSpec.world).to receive(:ordered_example_groups).and_return([])
    allow_any_instance_of(OpenMutator::Inserter).to receive(:insert)
  end

  it "emits killed when examples fail" do
    allow(rspec_runner).to receive(:run_specs).and_return(1)
    run_worker
    expect(emitted).to eq("status" => "killed", "details" => nil)
  end

  it "emits survived when examples pass" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    run_worker
    expect(emitted).to eq("status" => "survived", "details" => nil)
  end

  it "loads specs BEFORE inserting the mutation" do
    calls = []
    allow(rspec_runner).to receive(:setup) { calls << :setup }
    allow_any_instance_of(OpenMutator::Inserter).to receive(:insert) { calls << :insert }
    allow(rspec_runner).to receive(:run_specs) do
      calls << :run_specs
      0
    end
    run_worker
    expect(calls).to eq(%i[setup insert run_specs])
  end

  it "emits error when insertion raises" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    allow_any_instance_of(OpenMutator::Inserter)
      .to receive(:insert).and_raise(SyntaxError, "boom")
    run_worker
    expect(emitted["status"]).to eq("error")
    expect(emitted["details"]).to include("SyntaxError", "boom")
  end
end
