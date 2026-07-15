# Dogfood log — payint active-mutator-poc

| Date | Phase | Command | Wall time | Score | Survivors | Notes |
|---|---|---|---|---|---|---|
| 2026-07-15 | pre-1 | `active_mutator app/models --subject "Document#size_category"` | 2.14s | 100.0% | 0 | baseline before fail-fast; 20 mutants, all killed, cached coverage map |
| 2026-07-15 | 1 (post #18) | `active_mutator app/models --subject "Document#size_category"` | 1.89s | 100.0% | 0 | fail-fast active; small subject, modest gain expected — larger sets benefit more |

## Findings

- 2026-07-15: positional path args are directory prefixes only — `active_mutator app/models/document.rb` globs `document.rb/**/*.rb`, finds 0 subjects, exits 0 vacuously. Silent false-green; candidate new issue: accept file paths (or error on non-directory args).
