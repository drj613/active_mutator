require "json"
require "tempfile"

RSpec.describe OpenMutator::Scheduler do
  def item(timeout: 5.0, lane: :parallel)
    OpenMutator::WorkItem.new(mutation: nil, example_ids: [], timeout: timeout, lane: lane)
  end

  def scheduler(worker:, jobs: 2, on_result: nil)
    described_class.new(jobs: jobs, worker: worker, on_result: on_result)
  end

  it "collects statuses reported by workers" do
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
    results = scheduler(worker: worker).run([item, item, item])
    expect(results.map(&:status)).to eq(%i[killed killed killed])
  end

  it "marks silent crashes as :error" do
    worker = ->(_m, _e, _w) { Process.exit!(1) }
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:error])
  end

  it "kills over-deadline workers and marks :timeout" do
    worker = ->(_m, _e, _w) { sleep 30 }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = scheduler(worker: worker).run([item(timeout: 0.2)])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(results.map(&:status)).to eq([:timeout])
    expect(elapsed).to be < 5
  end

  it "invokes on_result as each result lands" do
    seen = []
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "survived", "details" => nil)) }
    scheduler(worker: worker, on_result: ->(r) { seen << r.status }).run([item, item])
    expect(seen).to eq(%i[survived survived])
  end

  it "respects the jobs cap" do
    worker = lambda do |_m, _e, writer|
      sleep 0.15
      writer.puts(JSON.generate("status" => "killed", "details" => nil))
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    scheduler(worker: worker, jobs: 2).run([item, item, item, item])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be >= 0.3 # 4 items / 2 jobs => at least two waves
  end

  it "runs serial-lane items one at a time, after the parallel lane" do
    # Workers run in forked child processes, so an in-memory Queue can't
    # observe cross-process ordering (fork gives each child its own copy —
    # pushes never reach the parent). Use a flock-guarded append log instead.
    log_path = Tempfile.new("order").path
    append = ->(line) { File.open(log_path, "a") { |f| f.flock(File::LOCK_EX); f.puts(line) } }
    worker = lambda do |_m, _e, writer|
      append.call("start")
      sleep 0.1
      append.call("finish")
      writer.puts(JSON.generate("status" => "killed", "details" => nil))
    end
    scheduler(worker: worker, jobs: 2).run([item(lane: :serial), item(lane: :serial)])
    events = File.readlines(log_path).map { |l| l.chomp.to_sym }
    expect(events).to eq(%i[start finish start finish]) # never two concurrent starts
  end
end
