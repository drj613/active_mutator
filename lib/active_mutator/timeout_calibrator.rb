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
  class TimeoutCalibrator
    WARMUP = 5
    # A real sliding window, not full-run history: a 500-mutant run's early
    # load regime must age out completely instead of anchoring the median
    # forever. 30 samples is enough for a stable median and small enough to
    # track load changes within a few dozen finishes.
    WINDOW = 30
    TARGET_UTILIZATION = 0.25
    MIN_SCALE = 0.5
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
