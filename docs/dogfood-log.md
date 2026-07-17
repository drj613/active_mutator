# Dogfood log — payint active-mutator-poc

| Date | Phase | Command | Wall time | Score | Survivors | Notes |
|---|---|---|---|---|---|---|
| 2026-07-15 | pre-1 | `active_mutator app/models --subject "Document#size_category"` | 2.14s | 100.0% | 0 | baseline before fail-fast; 20 mutants, all killed, cached coverage map |
| 2026-07-15 | 1 (post #18) | `active_mutator app/models --subject "Document#size_category"` | 1.89s | 100.0% | 0 | fail-fast active; small subject, modest gain expected — larger sets benefit more |
| 2026-07-15 | 1 close | `--subject "Document" --debug-plan` | n/a | n/a | n/a | bare-constant expr plans 115 mutants across class; JSON valid |
| 2026-07-15 | 1 close | `--subject "Document#size_category" --max-mutants 5` | n/a | 100.0% | 0 | exactly 5 mutants run |
| 2026-07-15 | 1 close | `--exclude "app/models/document.rb"` + subject | n/a | n/a | 0 | target excluded → 0 mutants (vs 20) |
| 2026-07-15 | 1 close | `--changed` | n/a | 100.0% | 0 | clean tree, 0 mutants — correct |
| 2026-07-15 | 2 close | `active_mutator app/models --subject "Document#size_category"` | 2.65s | 100.0% | 0 | smoke run; 20 mutants, all killed |
| 2026-07-15 | 2 close | `--subject "Document" --format stryker-json` | n/a | n/a | 15 | 115 mutants in report; schemaVersion 2, 1 file, testFiles present, valid JSON; exit 1 (survivors) |
| 2026-07-15 | 2 close | `--subject "Document" --format github` | n/a | n/a | 15 | 15 `::warning` annotations, one per survivor; exit 1 |
| 2026-07-16 | 3 close | `active_mutator lib/active_mutator/config_file.rb` | 1.42s | 100.0% | 0 | file-path positional arg works (#23 fix); 64 mutants, all killed, exit 0 |
| 2026-07-16 | 3 close | same, with `.active_mutator.yml` (`jobs: 2`) | 2.46s | 100.0% | 0 | config file applied: CPU 230% → 116%, wall 1.42s → 2.46s (2 workers); yml deleted after |
| 2026-07-16 | 3 close | `active_mutator lib/nope.rb` | n/a | n/a | n/a | `no such file or directory: lib/nope.rb`, exit 2 — no more silent false-green |
| 2026-07-16 | 3 close | `active_mutator README.md` | n/a | n/a | n/a | `not a Ruby file: README.md`, exit 2 |
| 2026-07-16 | 3 close | `active_mutator lib` (full gate) | n/a | 100.0% | 0 | 1094 killed, 8 timeout, 25 accepted; first pass showed 9 phantom survivors in `Runner#prune_scope` from a stale incremental baseline — one `--force-baseline` refresh killed all of them, exit 0 |
| 2026-07-16 | 4 pre-#9 | `bin/bench` (fixture corpus) | tiny j1/j2 + rails j2 mutation-stage seconds: 1.05 / 0.65 / 0.83 (baselines 0.35 / 0.31 / 1.49) | n/a | n/a | pinned bench/baselines/tiny_project-jobs2; static timeouts; tiny cells exit_ok false = planted survivors (expected); rails_app exit_ok false was a fixture flake (DB state leakage on the `.adults` boundary mutant), fixed by pinning a user aged exactly 18 |
| 2026-07-16 | 7 post-#9 | `bin/bench` (fixture corpus, cells run `--no-adaptive-timeout`) | tiny j1/j2 + rails j2 mutation-stage seconds: 0.94 / 0.68 / 0.74 (baselines 0.32 / 0.31 / 1.5) | n/a | n/a | bench-diff vs pinned tiny_project-jobs2 baseline: score 89.47 → 89.47 (delta 0.0), exit 0 — plumbing changed nothing with adaptive off. Manual adaptive-on run (`tiny_project lib --jobs 2`) matched the pinned statuses (2 planted `discount` survivors, 0 timeouts, 89.5%); one `adaptive timeout scale (parallel): 0.5` stderr line, no Killed↔Timeout flip |

## Findings

- 2026-07-15: `--accept-survivors` on a scoped run (`--subject`/`--changed`) rewrites the ledger to only fingerprints seen in THAT run — silently deletes out-of-scope acceptances (lost the 3 Worker#run entries when accepting a SubjectFinder one; recovered by manual merge). Candidate new issue: ledger accept! must merge, pruning only true stale entries, or prune only within the run's discovery scope.
- 2026-07-15: positional path args are directory prefixes only — `active_mutator app/models/document.rb` globs `document.rb/**/*.rb`, finds 0 subjects, exits 0 vacuously. Silent false-green; candidate new issue: accept file paths (or error on non-directory args).
