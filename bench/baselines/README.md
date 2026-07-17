# Pinned bench baselines

Committed Stryker reports from known-good runs. Compare a fresh run against
a pinned baseline with:

    bin/bench --out /tmp/bench-now
    bin/bench-diff bench/baselines/tiny_project-jobs2.mutation-report.json \
                   /tmp/bench-now/tiny_project-jobs2/mutation-report.json

Exit 0 = no status transitions, no added/removed mutants. Any scheduler,
timeout, or operator change must keep this diff clean (or update the pin
with an explanation in the commit message).

Wall times live in each run's bench.json and are environment-dependent —
they are logged in docs/dogfood-log.md, never pinned.
