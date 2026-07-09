# open_mutator — Design

**Date:** 2026-07-09
**Status:** Approved

## Summary

`open_mutator` is an open-source mutation testing tool for Ruby, designed from
the ground up as a modern successor to prior-generation tools. It is
pure Ruby, built on Prism (Ruby's official parser), integrates with RSpec, and
is designed Rails-first: application preload, fork-safe workers, and
coverage-based test selection so mutation runs are practical on large
applications with slow suites.

## Motivation

- **License freedom.** Established Ruby mutation testing tools require a paid
  license for commercial use. open_mutator is fully open source.
- **Modern parser stack.** Prior-generation tools depend on the
  `parser`/`unparser` gems and lag every new Ruby release. Prism is maintained
  by Ruby core and supports new syntax on release day.
- **Performance.** Coverage-based test selection, fork-pool parallelism, and
  incremental (`--since`) runs make mutation testing viable in CI on a Rails
  monolith.
- **Learning.** The codebase is small, boundary-clean, and understandable —
  a working education in mutation testing internals.

## Core architectural decision: source-span mutations

open_mutator does **not** mutate ASTs and unparse them back to source
(the classic approach — which requires an unparser, the single largest and
riskiest component of that design; no unparser exists for Prism).

Instead, mutation operators walk the Prism AST but emit **text edits**:

```
Edit = (byte_range, replacement_string, description)
```

Applying a mutation = splicing the replacement into a fresh copy of the
original file text at the given byte range. Consequences:

- No unparser is ever built or maintained.
- Every byte outside the edit is untouched by construction; diffs shown to
  users are their exact source.
- Bug blast-radius is per-operator, not systemic.
- A universal validity gate exists: re-parse the mutated text with Prism and
  discard any mutant that fails to parse.
- New Ruby syntax is Prism's problem, not ours; byte spans don't care.

Restructuring mutations (e.g. `a && b` → `b`, argument swaps) are expressed
by building the replacement string from other nodes' extracted source spans.

Prism reports **byte** offsets; all splicing is byte-wise (multibyte-safe).
Each mutant applies one edit-set to a fresh copy, so overlapping edits cannot
occur.

## Architecture

```
CLI/Config → Subject Finder → Mutation Engine → Scheduler ⇄ Workers → Reporter
                                   ↑
                            Coverage Map (baseline run, cached)
```

Data flows one direction. Component boundaries:

### 1. Subject Finder

Walks target files with Prism and yields **subjects**: methods (instance,
class, and singleton) with their constant scope, file path, and byte span.

Filters:
- `--since <ref>` — only methods overlapping changed lines in `git diff <ref>`
- path globs (include/exclude)
- `--subject 'Foo::Bar#method'` — single-subject filter for dev loops
- per-method opt-out via magic comment

### 2. Mutation Engine

A catalog of operators. Each operator is a pure function over Prism nodes:

```ruby
applies?(node)        → bool
edits(node)           → [Edit(byte_range, replacement, description)]
```

No state, no I/O. A validity gate applies each edit to a source copy,
re-parses with Prism, and discards syntax-invalid mutants (status `invalid`,
excluded from score).

**v1 catalog (~20 operators), chosen for kill value:**
- conditional boundaries: `>` ↔ `>=`, `<` ↔ `<=`
- condition forcing: `cond` → `true`, `cond` → `false`
- logical operators: `&&` ↔ `||`; drop left/right operand
- literal mutation: integers (`0` → `1`, `n` → `n±1`), strings (`"s"` → `""`),
  booleans, `nil` returns
- statement deletion
- method-call swaps: `.map` → `.each`, negation removal
- Rails-aware pack: `.present?` ↔ `.blank?`, `.save` ↔ `.save!`, and similar
- early-return removal

### 3. Coverage Map

One instrumented baseline RSpec run (per-example line coverage via `Coverage`)
produces an inverted index:

```
{ "path/to/file.rb:42" => [example_id, ...] }
```

Serialized to a cache directory (`.open_mutator/`). Also produced by the
baseline run:
- **baseline pass check** — the suite must be green before mutating
- per-example runtimes — used to compute mutation timeouts

Invalidation is coarse and dumb in v1: the map is keyed by source-file
digests plus a spec-set digest; any mismatch triggers a full baseline re-run.
Fine-grained re-instrumentation is a v2 concern.

### 4. Scheduler

The parent process preloads the Rails environment once (boot + eager load),
then runs a fork pool sized to available CPUs. One mutation per fork.

Worker lifecycle:
1. Apply the edit-set to an in-memory copy of the file text.
2. Extract the enclosing `def` span from the mutated text.
3. `eval` it within the subject's constant scope — redefining the method.
4. Run the covering examples in-process via the RSpec runner API.
5. Exit with kill status.

Fork gives free isolation: no un-mutating, and global-state bleed dies with
the process.

### 5. Worker Rails hygiene

After-fork hooks: re-establish ActiveRecord connections, clear connection
pools, reseed randomness.

Per-mutation timeout = `baseline example time × factor + floor`. Timeout is
its **own status**, not a kill — infinite-loop mutants are real (`<` → `<=`
in a loop condition) and must be distinguishable.

### 6. Reporter

Statuses:

| Status      | Meaning                                        | In score? |
|-------------|------------------------------------------------|-----------|
| `killed`    | covering examples failed                       | yes       |
| `survived`  | covering examples passed                       | yes       |
| `timeout`   | examples exceeded computed timeout             | yes — counts as detected |
| `error`     | worker crashed or mutant raised at eval time   | reported separately |
| `invalid`   | mutated text failed re-parse                   | excluded  |
| `uncovered` | no examples cover the mutated line             | reported loudly — coverage debt |

Mutation score = `(killed + timeout) / (killed + timeout + survived)`.

Output: live progress, end summary with exact-source diffs for survivors,
mutation score. `--format json` for CI.

## Error handling

- **Baseline gate:** red baseline aborts with a clear message.
- **Worker crashes** become status `error` and never poison the run.
- **Process hygiene:** workers run in their own process group; the parent
  traps INT/TERM and reaps the pool. No orphaned Rails processes.
- **Stale coverage map:** digest mismatch → full baseline re-run (v1).
- **Equivalent mutants** (behaviorally identical to original) are undecidable
  in general; mitigation is operator curation, not detection. Some survivor
  noise is inherent to mutation testing.

## Scope honesty

Insertion works by re-eval'ing a mutated `def` in its constant scope, so v1
mutates **method bodies only**. Not mutated: class-level macros, constants,
DSL blocks (`validates`, scope lambdas). This is a documented limit, not a
surprise.

## Incremental mode

- `--since origin/main` — mutate only methods touched in the diff. This is
  the CI story: PR runs take minutes, full runs happen nightly/on-demand.
- `--subject 'Billing::Calculator#total'` — tight dev loop on one method.

## Testing strategy (for open_mutator itself)

- **Operators:** golden tests — Ruby snippet in, expected
  `(description, mutated_source)` pairs out. Pure, no forking, milliseconds.
  The bulk of the suite.
- **Property gate (CI):** run all operators over a corpus of real-world Ruby
  files; assert 100% of emitted mutants re-parse with Prism.
- **Coverage map:** fixture RSpec project; assert inverted-index contents.
- **End-to-end:** minimal fixture Rails app in `spec/fixtures/` with planted
  known-survivor and known-killed mutants; run the full pipeline; assert
  statuses. Eventual goal: self-hosting (open_mutator run on itself).

## v1 scope

| In | Out (v2 or never) |
|---|---|
| RSpec integration | minitest |
| ~20-operator catalog + Rails-aware pack | operator plugin API |
| Coverage-based test selection | convention/hybrid mapping |
| Fork-pool parallelism | cross-machine distribution |
| `--since`, `--subject` filters | full subject-expression language |
| Terminal + JSON reports | HTML report, editor integration |
| Linux/macOS | Windows (MRI fork required) |

## Decisions log

| Decision | Choice | Rejected alternatives |
|---|---|---|
| Language | Pure Ruby | Rust core + Ruby runner (two toolchains, kill step needs Ruby anyway) |
| Parser | Prism | `parser`/`unparser` (syntax lag, unparser maintenance) |
| Mutation representation | Source-span text edits | AST mutation + new Prism unparser (months of fidelity work, systemic bug risk); runtime/ISeq patching (fragile, version-coupled) |
| Test selection | Coverage-based map | Convention mapping (imprecise on Rails); hybrid (two systems) |
| Isolation | Fork per mutation | In-process un-mutating (state bleed), spawn (loses preload) |
| Test framework | RSpec only in v1 | Both day one (doubles integration work); agnostic command (no test selection) |
| Target | Rails-first | Gems-first (easier but lower value) |
