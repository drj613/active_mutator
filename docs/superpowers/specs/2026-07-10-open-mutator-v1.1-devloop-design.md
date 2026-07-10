# open_mutator v1.1 — Dev-Loop Era

**Date:** 2026-07-10
**Status:** Draft — pending review
**Builds on:** `2026-07-09-open-mutator-design.md` (v1, shipped)

## Goal

Make mutation testing fast and cheap enough to run inside the development
loop — specifically: agentic TDD reaches green, then a scoped mutation run
verifies the new tests actually constrain the new behavior, and survivors
are fed back as machine-readable test gaps.

Three workstreams, in priority order:

1. **Hot-parent fork sharing** — stop paying RSpec setup in every fork
2. **Incremental baseline** — stop re-running the whole instrumented suite
   on every file change
3. **Dev-loop integration** — CLI affordances + an agent-facing skill that
   closes the TDD → mutate → strengthen loop

Empirical motivation (payint, real Rails monolith, 515 mutants): per-fork
RSpec setup dominated worker cost (~10–20s each), oversubscription turned 60
honest kills into false timeouts, and the coarse baseline invalidation makes
every dev-loop iteration pay a full instrumented suite run.

---

## Workstream 1: Hot-parent fork sharing

### 1a. Parent preloads the spec environment

Today the parent preloads only the app (`config/environment` + eager load);
every fork pays `rails_helper`/`spec_helper` (rspec-rails glue, support dir,
factories, VCR config) again.

Change: after `preload!`, the Runner also requires the project's spec helper
**once in the parent**. Forks inherit it via copy-on-write.

- Detection order: `spec/rails_helper.rb`, else `spec/spec_helper.rb`, else
  nothing (still works, just slower). Overridable with
  `--preload-helper FILE` / `--no-preload-helper`.
- The worker's `--require spec_helper` from `.rspec` becomes a no-op because
  the file is already in `$LOADED_FEATURES` (verified: helper body runs
  exactly once), and per-fork spec loading covers only the covering spec
  files (typically 1–5).
- **World-group hygiene (critical):** helpers transitively evaluate
  top-level example groups surprisingly often (`spec/support/**` files with
  `RSpec.describe` at load time). Those groups land in `RSpec.world` in the
  parent, every fork inherits them, and `run_specs(ordered_example_groups)`
  would run them *in addition to* the covering examples — a leaked failing
  group reports as a false `killed` and silently inflates the score. The
  worker therefore MUST NOT run all of `RSpec.world`: it runs only groups
  whose `metadata[:absolute_file_path]` belongs to the covering spec files
  (equivalently: discards every group present in a snapshot taken right
  after parent preload). `RSpec.shared_examples` are unaffected (separate
  registry).
- **SimpleCov disarm:** projects commonly `SimpleCov.start` in the helper.
  In the parent that means (a) its `at_exit` fires at the end of the whole
  mutation run and overwrites the project's real `coverage/` data with
  parent noise, and (b) `minimum_coverage` makes it `exit 1`, corrupting our
  exit code. After preload, if `defined?(SimpleCov)`, the Runner neutralizes
  its at_exit (`SimpleCov.at_exit { }`). Additionally every open_mutator
  process (parent, forks, baseline subprocess) sets `ENV["OPEN_MUTATOR"] =
  "1"` so host projects can guard coverage/profiling setup themselves; the
  README documents this as the recommended pattern. (Baseline subprocess
  already coexists: modern SimpleCov guards on `Coverage.running?` and
  degrades rather than crashes.)
- The v1 "load specs before inserting" ordering stays exactly as is — it is
  still correct, and with the helper preloaded it is no longer expensive.
- `before(:suite)` hooks still run per fork (verified: RSpec runs them
  inside `run_specs`, not setup) — correct: each fork needs its own suite
  state (DatabaseCleaner, etc.).

Consequence for timeout budgets: fork boot cost collapses to
covering-file load + suite hooks, so budgets derived from example times
become honest. Defaults stay `factor 8 / floor 10` and get revisited with
measurements after this ships.

### 1b. Serial lane for browser-covered mutants

System/feature specs boot Chrome + an app server per fork; sockets do not
survive fork, so this cost cannot be shared. Running many of these
concurrently is what melts CPUs and produces the false-timeout population.

Change: Runner partitions work items into two lanes:

- `:parallel` — default lane, jobs = configured concurrency
- `:serial` — any mutant whose covering examples include a path matching the
  browser-spec patterns (default `spec/system/`, `spec/features/`;
  configurable `--serial-pattern`, repeatable)

Scheduler API: `run(items)` becomes lane-aware — parallel lane first at full
concurrency, then serial lane at `jobs: 1`. One scheduler, two passes; the
reporter sees a single stream (it has no ordering assumptions). Serial-lane
items also get a budget bump (browser boot constant, default +15s,
`--browser-boot-seconds`).

Deliberate cost choice: a mutant covered by both unit and browser examples
goes entirely serial and runs its browser examples too. Dropping the
browser examples to stay parallel would be faster but unsound — if only the
browser spec kills the mutant, dropping it manufactures a false survivor.
Correctness wins; the perf cost is bounded to the browser-covered subset.

### Explicitly rejected: persistent workers (un-insert between mutations)

Restoring the original method between mutations in a long-lived worker leaks
cross-mutation state (memoization, class state, DB residue from killed
runs) and silently corrupts results. Fork-per-mutation is the correctness
guarantee; 1a+1b capture most of the win without touching it.

---

## Workstream 2: Incremental baseline

### Cache format v2

v1 stores only the inverted map (`file:line → [example_ids]`), which cannot
be surgically updated. v2 stores the primary records and derives the map:

```json
{
  "version": 2,
  "records": { "./spec/a_spec.rb[1:1]": [["/abs/lib/a.rb", 3], ...] },
  "times":   { "./spec/a_spec.rb[1:1]": 0.51 },
  "digests": { "lib/a.rb": "sha256...", "Gemfile.lock": "sha256..." }
}
```

`CoverageMap` builds the inverted index in memory on load (cheap). Cache is
disposable: on version mismatch or any structural doubt, full re-run — no
migration code ever.

`Gemfile.lock` and `.rspec` join the digest set (dependency or RSpec config
changes → full re-run).

### Delta refresh

On digest mismatch, compute three sets instead of re-running everything:

| Change detected | Refresh action |
|---|---|
| Spec file changed/added | Re-run that spec file instrumented; drop all records whose example id belongs to it; merge new records |
| Source file changed | Re-run (instrumented) the union of examples currently covering any line of that file; replace those examples' records wholesale |
| Spec file deleted | Drop its records |
| Source file deleted | Drop it from all records |
| Any change/delete under `spec/support/**` (or any spec-dir file owning no example records) | Full re-run — shared examples/support code is attributed to *using* files, so the delta path can neither find its records nor safely re-run it |
| Rename / `.rspec` / `Gemfile.lock` / version mismatch / anything ambiguous | Full re-run (the v1 path, kept as fallback) |

Cache and ledger writes use advisory file locking (`File#flock`) with
write-to-temp + atomic rename — concurrent runs in the same repo root (an
agent plus a human, exactly the dev-loop case) must not corrupt state.
Distinct git worktrees are naturally safe (root-relative paths).

Mechanics: `Baseline#refresh!(targets)` shells out to the same instrumented
`rspec` invocation but with specific files/example ids as arguments; the
partial payload is merged into the cached records. The partial run must be
green (same baseline gate); a red partial run aborts with the same
`BaselineFailed`.

### Accepted imprecision (documented, not solved)

- **Newly-covering examples are missed.** "Re-run examples currently
  covering the changed file" cannot discover an example in an *unchanged*
  spec file that only starts covering the changed source after the edit
  (e.g. a pre-existing shared/parameterized test now reaching a new branch).
  Consequence: false `uncovered`/`survived` on such lines until the next
  full baseline. This is the delta model's real unsoundness — the nightly
  `--force-baseline` run exists specifically to recover it, and the
  mutation-check skill tells agents that a survivor on a line whose
  coverage looks implausibly thin warrants `--force-baseline` before
  writing new tests.
- Load-time line attribution can differ between a partial run and a full
  run. In practice this barely matters here: only method bodies are
  mutated, and body lines are attributed to calling examples at call time,
  not load time.
- The green-suite guarantee weakens: a partial green + previously-green
  cache does not prove the whole suite is green *now*. Dev-loop stakes are
  low (the agent just ran the suite); CI should use `--force-baseline`
  periodically (nightly full run).

---

## Workstream 3: Dev-loop integration

### CLI affordances

- `--changed` — alias for `--since HEAD` (uncommitted work, staged +
  unstaged), the inner-loop default. Additionally, **untracked** `.rb`
  files (`git ls-files --others --exclude-standard`) are treated as fully
  changed — every method in them is a subject. Without this, agentic TDD's
  most common case (brand-new file + brand-new spec) would be silently
  skipped; this closes the v1 `SinceFilter` known limit for both `--changed`
  and `--since`. Implementation note: `SinceFilter` is a line-list model, so
  untracked files need a whole-file sentinel in `cover?`, not just appended
  line numbers. Gitignored `.rb` files stay excluded (`--exclude-standard`).
  Untracked *spec* files already feed baseline invalidation (digests come
  from `Dir[]`, not git) — now stated explicitly.
- **Survivor acceptance ledger** — equivalent mutants are undecidable, so
  the loop needs a way to say "this survivor is fine":
  - **`.open_mutator_accepted.json` at the repo root** — deliberately NOT
    inside `.open_mutator/`: the cache dir is gitignored and disposable,
    while acceptance decisions are durable team/CI state that must be
    committed (the PR recipe `--since origin/main` must honor them or CI
    exits 1 on known equivalents forever).
  - Fingerprint: `{file, subject, description, original_snippet, ordinal}`
    where `ordinal` is the mutant's position among identical
    `(description, original_snippet)` pairs within the subject, in source
    order. Line-number independent (survives moves), but distinguishes
    duplicates — without it, `a > 0 && b > 0` yields two byte-identical
    fingerprints and accepting one silently accepts both, hiding a real
    gap. Statement reordering within a method invalidates ordinals;
    acceptable, re-accept.
  - Mutants matching a fingerprint report as new status **`accepted`**
    (excluded from score denominator like `invalid`, listed in output).
  - `--accept-survivors` — run, then append current survivors to the
    ledger (the explicit human/agent escape hatch).
  - Staleness: every run prunes non-matching fingerprints in memory and
    warns about them (file renames orphan fingerprints — re-accept after
    renames); the file itself is rewritten (pruned) on `--accept-survivors`.
  - Exit code stays: 1 only if **unaccepted** survivors exist.
- JSON output gains `"accepted"` in counts/results and a top-level
  `"exit_reason"` field.

### The loop contract (what an agent runs)

```
tests green
  → open_mutator --changed --format json
  → survivors? each is a concrete test gap: file, line, exact diff
  → strengthen tests (or --accept-survivors with justification)
  → repeat until exit 0
```

Because `--changed` scopes subjects to touched methods, every survivor is on
changed code by construction — no ratchet bookkeeping needed beyond the
acceptance ledger.

### Skill deliverable

`docs/skills/mutation-check.md` in the repo — a Claude Code skill (plain
markdown, installable by copying into `~/.claude/skills/` or a plugin)
that instructs an agent to:

1. Run the loop contract above after tests pass on any behavioral change.
2. Treat each survivor as a failing requirement: write the test that kills
   it (the diff tells you exactly what behavior is unconstrained).
3. Accept a survivor only with a stated equivalence argument (e.g. "`n+1`
   vs `n.succ` — no observable difference"), never for convenience.
4. Never weaken the mutation config to pass.

Plus a README for the gem: install, CI recipe (`--since origin/main` on PR,
nightly full), dev-loop recipe, all flags.

### Cadence (documented in README)

| When | Command | Expected cost after WS1+WS2 |
|---|---|---|
| Inner loop, tests just passed | `open_mutator --changed` | seconds |
| Pre-commit / PR CI | `open_mutator --since origin/main` | ~1–3 min |
| Nightly CI | `open_mutator --force-baseline` (full) | tens of minutes |

---

## Out of scope for v1.1

Adaptive budget calibration from observed worker wall times · shared-browser
pooling for system specs · minitest · per-method opt-out comment (still
first backlog item) · everything else in the v1 backlog.

## Decisions log

| Decision | Choice | Rejected alternatives |
|---|---|---|
| Fork-cost sharing | Parent preloads spec helper; forks load covering files only and run ONLY covering-file example groups (world-group snapshot filter) | Full-world preload + in-fork filter_manager id filtering (RSpec-internals risk, marginal extra win); persistent workers with un-insert (isolation loss); trusting `RSpec.world` as-is (leaked helper-load groups cause false kills — verified) |
| Browser-spec handling | Serial lane by covering-path pattern + budget bump | Shared browser pool (fork-unsafe), banning system specs from selection (loses kill signal) |
| Cache evolution | v2 with primary per-example records; regenerate on version mismatch | In-place migration (needless complexity for a disposable cache) |
| Incremental unit | File-level deltas, example-level re-runs | Line-level diffing of coverage (fragile), always-full (status quo, too slow for dev loop) |
| Equivalent-mutant handling | Fingerprint (with duplicate-ordinal) ledger at committed repo-root path + `accepted` status | Score thresholds (arbitrary), inline magic comments (couples source to tool), ledger inside gitignored cache dir (uncommittable — breaks CI recipe) |
| Dev-loop scope | `--changed` = `--since HEAD` | Watch mode/daemon (v2 territory) |
