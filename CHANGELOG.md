# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed

- Orphan watchdog: if the parent process is killed in a way it cannot trap
  (SIGKILL, closed terminal, CI teardown), the scheduler now detects the
  reparenting, kills all running workers, and aborts. Before this fix an
  orphaned run kept forking through the whole mutant queue unsupervised,
  which could exhaust the machine's CPU.

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
