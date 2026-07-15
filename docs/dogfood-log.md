# Dogfood log — payint active-mutator-poc

| Date | Phase | Command | Wall time | Score | Survivors | Notes |
|---|---|---|---|---|---|---|
| 2026-07-15 | pre-1 | `active_mutator app/models --subject "Document#size_category"` | 2.14s | 100.0% | 0 | baseline before fail-fast; 20 mutants, all killed, cached coverage map |
| 2026-07-15 | 1 (post #18) | `active_mutator app/models --subject "Document#size_category"` | 1.89s | 100.0% | 0 | fail-fast active; small subject, modest gain expected — larger sets benefit more |

## Findings

- 2026-07-15: `--accept-survivors` on a scoped run (`--subject`/`--changed`) rewrites the ledger to only fingerprints seen in THAT run — silently deletes out-of-scope acceptances (lost the 3 Worker#run entries when accepting a SubjectFinder one; recovered by manual merge). Candidate new issue: ledger accept! must merge, pruning only true stale entries, or prune only within the run's discovery scope.
- 2026-07-15: positional path args are directory prefixes only — `active_mutator app/models/document.rb` globs `document.rb/**/*.rb`, finds 0 subjects, exits 0 vacuously. Silent false-green; candidate new issue: accept file paths (or error on non-directory args).
