---
name: mutation-check
description: Use after tests pass on any behavioral code change. Runs scoped mutation testing to verify the new tests actually constrain the new behavior, and drives fixing every surviving mutant.
---

# Mutation Check

Green tests prove your tests pass. They do not prove your tests *constrain
the behavior you just wrote*. This skill closes that gap.

## When

After the test suite passes on any change that adds or modifies behavior
(new methods, changed logic). Skip for pure refactors with no behavior
change, docs, config.

## The loop

1. Run: `bundle exec active_mutator --changed --format json`
2. Exit 0 → done. Report the mutation counts and move on.
3. Exit 1: read `results` where `"status": "survived"`. Each survivor is a
   concrete, machine-verified test gap. It is the exact source span (`file`,
   `line`, `original`, `replacement`) that can change without any test
   noticing.
4. For each survivor, write the test that kills it. The diff tells you
   exactly what behavior is unconstrained. Assert on it.
5. Re-run step 1. Repeat until exit 0.

## Accepting equivalent mutants

Some mutants cannot be killed because they don't change observable behavior
(e.g. `n + 1` → `n.succ`-shaped equivalences, defensive guards provably
unreachable). Accept one ONLY with a stated equivalence argument:

- Say WHY no test can distinguish the mutant, in one sentence.
- Then: `bundle exec active_mutator --changed --accept-survivors`
- The acceptance ledger (`.active_mutator_accepted.json`, repo root) is
  committed state. Include it in your commit.
- Scoped accepting runs are safe: the ledger never prunes out-of-scope
  entries (pruning happens only within files fully scanned by
  non-narrowed runs).

Team-wide defaults (jobs, excludes, serial patterns, etc.) live in
`.active_mutator.yml` at the project root; CLI flags override it.
`--fail-at SCORE` can gate on score instead of zero-survivors for legacy
suites — do not add it to make your own change pass.

Never accept a survivor because killing it is tedious. Never weaken
active_mutator flags (`--subject` scoping, patterns) to make a run pass.

## Interpreting other statuses

- `uncovered`: no example executes the mutated line at all. This is a
  missing-test smell stronger than a survivor. Write coverage first.
- `timeout`: counts as detected (likely an infinite-loop mutant). Fine.
- If a survivor's coverage looks implausibly thin (you KNOW a test covers
  that line), the incremental baseline may be stale in the
  newly-covering-example blind spot. Re-run once with `--force-baseline`
  before writing new tests.
