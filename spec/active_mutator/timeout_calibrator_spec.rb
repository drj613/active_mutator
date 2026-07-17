RSpec.describe ActiveMutator::TimeoutCalibrator do
  def item(timeout: 20.0, variable: 8.0, boot_extra: 0.0)
    ActiveMutator::WorkItem.new(mutation: nil, example_ids: [], timeout: timeout,
                                lane: :parallel, variable: variable, boot_extra: boot_extra)
  end

  it "returns a neutral scale of 1.0 on an empty window instead of raising" do
    expect(described_class.new.scale).to eq(1.0)
  end

  it "returns the static budget before warm-up completes, and reports warmed? accordingly" do
    cal = described_class.new
    4.times { cal.record(19.0, 20.0) } # 4 < WARMUP
    expect(cal.warmed?).to be false
    expect(cal.budget_for(item)).to eq(20.0)
    cal.record(19.0, 20.0)
    expect(cal.warmed?).to be true
  end

  it "grows remaining budgets when observed utilization exceeds the target" do
    cal = described_class.new
    5.times { cal.record(15.0, 20.0) } # utilization 0.75, scale 3.0
    # variable 8.0 * 3.0 + fixed (20.0 - 8.0) = 36.0
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(36.0)
  end

  it "never shrinks below the static budget: low utilization clamps the scale to 1.0" do
    cal = described_class.new
    5.times { cal.record(0.2, 20.0) } # utilization 0.01 -> would shrink, but clamps to 1.0
    # variable 8.0 * 1.0 + fixed 12.0 = 20.0 (== static item.timeout)
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(20.0)
  end

  it "clamps a warmed window of very low utilizations to the static budget (grow-only)" do
    cal = described_class.new
    10.times { cal.record(1.0, 20.0) } # utilization 0.05, well below target
    item = item(timeout: 20.0, variable: 8.0)
    expect(cal.warmed?).to be true
    expect(cal.budget_for(item)).to eq(item.timeout) # scale clamps to 1.0, never below
  end

  it "clamps growth at 4x" do
    cal = described_class.new
    5.times { cal.record(20.0, 20.0) } # utilization 1.0 -> 4.0 capped
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(44.0)
  end

  it "recovers from a pinned-high scale because utilization is measured against the effective budget" do
    cal = described_class.new
    5.times { cal.record(20.0, 20.0) }   # load spike: utilization 1.0 -> scale 4.0
    expect(cal.scale).to eq(4.0)
    # Subsequent forks ran under 4x-scaled budgets (80.0); the same honest
    # 20s kills now record utilization 0.25 against the budget they ACTUALLY
    # had. Median: sorted [0.25 x6, 1.0 x5] -> 0.25 -> scale back to 1.0.
    6.times { cal.record(20.0, 80.0) }
    expect(cal.scale).to eq(1.0)
  end

  it "bounds the sample window so an old load regime ages out completely" do
    cal = described_class.new
    30.times { cal.record(20.0, 20.0) } # sustained spike: utilization 1.0 -> scale 4.0
    expect(cal.scale).to eq(4.0)
    30.times { cal.record(5.0, 20.0) }  # 30 fresh samples displace the WINDOW entirely
    expect(cal.scale).to eq(1.0)        # median over the surviving window is 0.25 exactly
  end

  it "uses the median, so one outlier does not swing the scale" do
    cal = described_class.new
    4.times { cal.record(5.0, 20.0) } # utilization 0.25 -> scale 1.0
    cal.record(20.0, 20.0)            # single outlier
    expect(cal.budget_for(item(timeout: 20.0, variable: 8.0))).to eq(20.0)
  end

  it "never scales the fixed part (floor + browser boot stay additive)" do
    cal = described_class.new
    5.times { cal.record(15.0, 20.0) } # scale 3.0
    serial = item(timeout: 35.0, variable: 8.0, boot_extra: 15.0)
    # 8.0 * 3.0 + (35.0 - 8.0) = 51.0 : the 15s browser boot and 12s floor untouched
    expect(cal.budget_for(serial)).to eq(51.0)
  end

  # Record a raw utilization value (elapsed / budget) with a fixed budget of 20.0.
  def rec(cal, util) = cal.record(util * 20.0, 20.0)

  it "takes the true middle element for an odd-sized window of distinct samples" do
    cal = described_class.new
    [0.20, 0.25, 0.30, 0.35, 0.40].each { |u| rec(cal, u) } # 5 distinct, median 0.30
    # median 0.30 / target 0.25 = scale 1.2 (picks sorted[2]=0.30, not sorted[1]=0.25 -> 1.0)
    expect(cal.scale).to be_within(0.0001).of(1.2)
  end

  it "averages the two middle elements for an even-sized window of distinct samples" do
    cal = described_class.new
    [0.10, 0.15, 0.20, 0.30, 0.35, 0.40].each { |u| rec(cal, u) } # 6 distinct
    # even median (0.20 + 0.30) / 2 = 0.25 / target 0.25 = scale 1.0
    expect(cal.scale).to be_within(0.0001).of(1.0)
  end

  it "caps the window at exactly WINDOW samples, dropping only the single oldest" do
    cal = described_class.new
    rec(cal, 0.10)                 # oldest; retained only if the cap is > WINDOW, not >=
    14.times { rec(cal, 0.20) }
    15.times { rec(cal, 0.30) }    # 30 samples total
    # 30 retained -> even median (0.20 + 0.30) / 2 = 0.25 -> scale 1.0.
    # If the oldest were also dropped (29 samples) the median would be 0.30 -> scale 1.2.
    expect(cal.scale).to be_within(0.0001).of(1.0)
  end

  it "ignores recordings with a non-positive budget" do
    cal = described_class.new
    5.times { cal.record(5.0, 0.0) }
    expect(cal.warmed?).to be false
    expect(cal.budget_for(item(timeout: 20.0))).to eq(20.0)
  end
end
