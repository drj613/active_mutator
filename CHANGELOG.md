# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [0.4.0] - 2026-08-10

- `--spec-path` / `spec_paths` config: spec discovery, coverage baseline,
  phase-2 escalation, and helper preload now honor non-standard spec
  directories (#35). Default (`spec/`) unchanged. Changing `spec_paths`
  between runs forces a full baseline; empty lists are a config error.
- Equivalent-mutant ledger re-audited (#34): 15 previously-accepted mutants
  are now killed by real tests, every remaining entry re-justified, and 12
  previously-untracked full-run survivors recorded as equivalent (47 → 45).
- An aborted baseline suite (e.g. output piped through a closed pipe) is no
  longer stamped as a fresh coverage map; the run now fails loudly instead
  of silently reporting every mutant uncovered.
- Class-body convention specs are discovered under every configured spec
  path, not just the first.
- Blank `--spec-path` entries are rejected; `--version` prints the version.

## [0.3.0] - 2026-07-30

### Added

- **Class-level mutation** (`#2`): Rails-style macros (`validates`, `scope`),
  constants, and DSL lambdas are now mutated, not just method bodies. Files
  with exactly one top-level class/module (Zeitwerk shape) get a `:class_body`
  subject covering their class-level code. Enabled by default; turn off with
  `--no-class-level`.
- **Closure reload**: class-level code can't be re-run with `class_eval`
  (re-running `validates` accumulates a validator), so the worker
  `remove_const`s the target plus its ObjectSpace closure — includers,
  subclasses, extenders — and re-evals their files in dependency-first order,
  mutated source for the target and pristine source for the rest.
  `class_level_closure_cap` (default 10) bounds how large that closure may get.
- **`ActiveSupport::Concern` DSL blocks**: code inside `included` and
  `class_methods` blocks is mutated (`#31`).
- **`skipped` status** for mutants whose closure can't be reloaded faithfully
  (over cap, reopened constant, anonymous or native attacher). Skipped mutants
  are left out of the score and shown by both reporters (`Ignored` in Stryker
  JSON).
- Class-body survivors are escalated to specs that reference the subject's
  constant before being reported as survivors, so a mutant that only a
  convention-named spec covers isn't miscounted.

### Fixed

- Worker requires the subject file before inserting a mutation, so RSpec's
  `described_class` binds to the reloaded object and non-preloaded projects
  keep working.
- Gemspec dependency bounds: `prism` is pinned `>= 0.30, < 2` (it is on 1.x, so
  `~> 0.30` would have excluded it) and the duplicate `homepage_uri` metadata
  entry is gone.

### Known limits

Only Zeitwerk-shaped files are covered — multi-constant files and core-class
reopens are out (`#32`). Code inside arbitrary blocks is not mutated (`#31`).
By-value constant captures (`ALIAS = SomeClass`) and `refine`-based modules go
stale across a reload.

## [0.2.0] - 2026-07-20

### Added

- **Operator plugin API**: define custom operators by subclassing
  `ActiveMutator::Operators::Base` (subclassing is registration), loaded
  via the repeatable `--operator FILE` flag or the `operators:` config-file
  key. Relative paths resolve against the project root. See
  `docs/guides/custom-operators.md`. The `Base` helpers (`edit`,
  `loc_range`) and `Edit` members are semver-stable from this release.
- **Heredoc mutation**: plain heredocs with a nonempty (dedented) body get
  an "empty heredoc body" mutant. Interpolated heredocs are untouched.
- **`class << self` mutation**: defs inside `class << self` within a
  constant scope are now discovered as singleton subjects and re-inserted
  through the singleton class. `class << obj` and top-level `class << self`
  stay skipped, as do classes/modules declared inside `class << self`
  (their constants live on the singleton class and are unreachable by
  name).
- **Nested def mutation**: bodies of defs nested inside another def are
  mutated under the outer subject (a nested def re-executes on every outer
  call, so a separate subject would produce phantom survivors).
- **Broader CallSwap pack**: `all?` → `any?`, `take` ↔ `drop`,
  `min_by` ↔ `max_by`, `sort` → `reverse`, `detect`/`find` → `first`.
- **Project config file**: `.active_mutator.yml` at the project root,
  layered under CLI flags (flags win).
- `--fail-at SCORE`: opt-in gate — exit 0 when the mutation score meets
  the threshold even with survivors.
- **Adaptive timeout calibration** (on by default, `--no-adaptive-timeout`
  to disable): grow-only budget scaling (1x–4x) from observed worker wall
  times, so parallel-load slowdown doesn't turn honest kills into false
  timeouts.
- Delta refresh now re-runs non-covering spec files that reference a
  changed file's constants, closing the newly-covering-example blind spot.
- `--format stryker-json` (mutation-testing-report-schema v2) and
  `--format github` (PR annotations for survivors).
- Per-operator equivalent-rate metric in run summaries.
- Subject expression language for `--subject` (`Foo::Bar#baz`, `Foo::Bar`,
  `Foo::Bar*`, `Foo::Bar#*`).
- `--exclude PAT` glob filtering (gitignore-like recursive semantics),
  `--max-mutants N` deterministic sampling, and `--debug-plan` dry run.
- Per-method opt-out via a `# active_mutator:skip` comment on the line
  above a def.
- Benchmark harness (`bin/bench`, `bin/bench-diff`) with a cross-run
  Stryker report differ.

### Fixed

- Positional path arguments: nonexistent paths error out, non-Ruby file
  args are rejected, overlapping path args are deduplicated.
- Scoped `--accept-survivors` no longer clobbers out-of-scope ledger
  entries; accepted fingerprints referencing missing files warn.
- Covering-example lookup widened to the subject's whole line range.
- Scheduler tolerates non-Hash JSON payloads from workers.
- Unloadable operator files and operators raising during analysis fail
  with attributed, friendly errors instead of raw stack traces.

## [0.1.1] - 2026-07-13

### Fixed

- Orphan watchdog: if the parent process is killed in a way it cannot trap
  (SIGKILL, closed terminal, CI teardown), the scheduler now detects the
  reparenting, kills all running workers, and aborts. Before this fix an
  orphaned run kept forking through the whole mutant queue unsupervised,
  which could exhaust the machine's CPU.
- The `.active_mutator/` cache directory now writes its own `.gitignore`
  on creation, so host projects can never commit the disposable coverage
  cache by accident.

## [0.1.0] - 2026-07-10

Initial release.

### Added

- Prism-based subject discovery: every instance, class, and singleton
  method (`def`) in target files, scoped by constant nesting.
- Source-span mutation engine: byte-range text edits against original file
  content, with a Prism re-parse validity gate (no unparser).
- Eight-operator catalog: `ConditionalBoundary`, `ConditionForcing`,
  `LogicalOperator`, `Literal`, `StatementDeletion`, `EarlyReturn`,
  `CallSwap` (including a Rails-aware pack: `present?`/`blank?`,
  `save`/`save!`), and `NegationRemoval`.
- Instrumented-baseline coverage map (cache format v2) mapping every
  source line to its covering RSpec examples and per-example run times.
- Incremental delta refresh: file-level, digest-driven partial re-runs
  instead of a full baseline re-run on every change, with `--force-baseline`
  as the full-recovery escape hatch.
- Fork-per-mutant kill pipeline: the parent preloads the application and
  spec helper once. Each mutant is inserted and exercised in an isolated
  fork against only its covering examples.
- World-group filtering so a fork runs only the example groups belonging to
  its covering spec files, never the full inherited `RSpec.world`.
- SimpleCov disarm in the parent process, and `ENV["ACTIVE_MUTATOR"] = "1"`
  set on every active_mutator process for host-project guards.
- Serial lane for browser-covered mutants (`spec/system/`, `spec/features/`
  by default), with its own timeout budget bump.
- Per-mutant timeout budget derived from baseline example times
  (`--timeout-factor`, `--timeout-floor`).
- `--changed` (uncommitted + untracked work) and `--since REF` (diff-scoped)
  subject filtering, plus `--subject NAME` for single-method runs.
- Committed acceptance ledger (`.active_mutator_accepted.json`) with
  ordinal-disambiguated fingerprints, `--accept-survivors`, and an
  `accepted` result status excluded from the mutation score.
- Terminal and JSON reporters; `killed`/`survived`/`timeout`/`error`/
  `uncovered`/`accepted` statuses, `invalid` mutant discarding, and a
  `--changed`-driven agent workflow (`docs/skills/mutation-check.md`).
- `active_mutator` executable and library API for programmatic use.
