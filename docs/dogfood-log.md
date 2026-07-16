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

## Findings

- 2026-07-15: `--accept-survivors` on a scoped run (`--subject`/`--changed`) rewrites the ledger to only fingerprints seen in THAT run — silently deletes out-of-scope acceptances (lost the 3 Worker#run entries when accepting a SubjectFinder one; recovered by manual merge). Candidate new issue: ledger accept! must merge, pruning only true stale entries, or prune only within the run's discovery scope.
- 2026-07-15: positional path args are directory prefixes only — `active_mutator app/models/document.rb` globs `document.rb/**/*.rb`, finds 0 subjects, exits 0 vacuously. Silent false-green; candidate new issue: accept file paths (or error on non-directory args).
