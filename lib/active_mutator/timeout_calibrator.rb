module ActiveMutator
  # Adaptive timeout budgets (#9). Static budgets derive from baseline times
  # measured warm and unloaded; under parallel load they misclassify
  # slow-but-honest kills as timeouts. The Scheduler feeds this with the
  # observed wall time of every KILLED fork (errors exit artificially fast,
  # survivors run their whole covering set — both would bias the median;
  # timed-out forks have no known wall time at all). One instance per lane:
  # parallel and serial run under different load regimes.
  #
  # Utilization is elapsed / the EFFECTIVE budget the fork ran under (the
  # value budget_for returned at its spawn), not the static item.timeout —
  # otherwise a pinned-high scale could never observe recovery (ratchet).
  # Once WARMUP observations exist, remaining budgets' variable part is
  # scaled by the clamped median utilization. The fixed part (timeout_floor
  # + browser boot) is never scaled: fork boot cost does not shrink because
  # examples run fast.
  #
  # The scale is grow-only (MIN_SCALE = 1.0): budgets may only extend beyond
  # the static value, never fall below it. Downscaling has no recovery signal
  # because timeouts are CENSORED samples — the scheduler skips them (they have
  # no known wall time), so only killed forks feed the window. A low median
  # utilization would shrink the budget, causing a legitimately slow kill to be
  # reaped as a timeout; that censored kill never enters the window, so nothing
  # ever pushes utilization back up. The shrink self-sustains — an asymmetric
  # ratchet. Growing is safe (a too-large budget still records a real kill and
  # relaxes); shrinking is not, so we forbid it.
  class TimeoutCalibrator
    WARMUP = 5
    # A real sliding window, not full-run history: a 500-mutant run's early
    # load regime must age out completely instead of anchoring the median
    # forever. 30 samples is enough for a stable median and small enough to
    # track load changes within a few dozen finishes.
    WINDOW = 30
    TARGET_UTILIZATION = 0.25
    MIN_SCALE = 1.0
    MAX_SCALE = 4.0

    def initialize
      @utilizations = []
    end

    def record(elapsed_seconds, budget)
      return unless budget.positive?

      @utilizations << elapsed_seconds / budget
      @utilizations.shift while @utilizations.size > WINDOW
    end

    def warmed? = @utilizations.size >= WARMUP

    def budget_for(item)
      return item.timeout unless warmed?

      fixed = item.timeout - item.variable
      item.variable * scale + fixed
    end

    def scale
      # An empty window has no median; a caller invoking scale without warmed?
      # (median of [] is nil) would otherwise raise. Neutral scale = no change.
      return 1.0 if @utilizations.empty?

      s = median(@utilizations) / TARGET_UTILIZATION
      s.clamp(MIN_SCALE, MAX_SCALE)
    end

    private

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
