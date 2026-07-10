# How it works

```
CLI/Config → Subject Finder → Mutation Engine → Scheduler ⇄ Workers → Reporter
                                   ↑
                            Coverage Map (baseline run, cached)
```

Data flows one direction. This guide walks each stage in the order a run
actually executes: find subjects, generate mutants, build/refresh the
coverage map, schedule and fork, report. It ends with an honest list of
what the design does not cover.

## 1. Subject discovery

`SubjectFinder` (`lib/active_mutator/subject_finder.rb`) is a `Prism::Visitor`.
It parses one file and walks it. It tracks constant scope (`class`/`module`
nesting) and yields a `Subject` (`{name, file, byte_range, line_range,
constant_scope, kind}`) for every `def` it finds, for example
`Billing::Calculator#total` or `Billing::Calculator.build`.

Two things it deliberately does **not** descend into:
- `class << self` bodies (`visit_singleton_class_node` is overridden to a
  no-op). This is a documented limit, not an oversight.
- Nested `def`s: `visit_def_node` does not call `super`. A method
  defined inside another method body is invisible to the finder. In
  practice, active_mutator's unit of mutation is exactly one method body:
  no class-macro calls (`validates`, `scope`, `has_many`), no constants,
  no DSL blocks.

`Runner#discover_subjects` globs `app/**/*.rb` and `lib/**/*.rb` (or
whatever paths/`--subject`/`--since` narrow it to) and hands each file to
`SubjectFinder.call`.

## 2. Source-span edits, not AST-to-source

One alternative design mutates the AST, then unparses it back into Ruby
source. That approach needs an unparser: a component that rebuilds source
from a tree, matching the original both syntactically and
*semantically*. It has to preserve everything from comment placement to
numeric literal formatting. Historically, the unparser is the largest and
riskiest part of that architecture, and no unparser exists for Prism today.

active_mutator sidesteps the problem entirely. Every operator
(`lib/active_mutator/operators/*.rb`) is a pure function:

```ruby
edits(node) -> [Edit(range, replacement, description)]
```

An `Edit` is a byte range into the **original file text** plus a
replacement string. It is never a new AST. Applying a mutation means
splicing the replacement into a byte copy of the original source
(`Splicer.apply`, `lib/active_mutator/splicer.rb`):

```ruby
bytes = source.b
edits.sort_by { |e| -e.range.begin }.each { |e| bytes[e.range] = e.replacement.b }
```

Edits are applied back-to-front, so earlier byte offsets never drift.
Every mutant applies exactly one edit to a fresh copy of the file, so
overlapping edits within a single mutant cannot occur.

Consequences of this design:
- No unparser is ever written or maintained. The byte range outside an
  edit stays untouched *by construction*, so the diff shown to you for a
  survivor is your exact source, verbatim.
- **The validity gate**: after splicing, `Engine#build_mutation`
  re-parses the mutated text with Prism. If it fails to parse, the mutant
  is discarded with status `invalid` (excluded from the score) instead of
  crashing a worker. This is the one universal correctness check every
  operator gets for free: an operator author cannot ship a mutant that
  doesn't parse.
- New Ruby syntax is Prism's problem, not active_mutator's. Byte spans
  don't care what's on either side of them.
- Restructuring mutations (operand drops in `LogicalOperator`, for
  example) work by re-slicing *other* nodes' source spans into the
  replacement string, not by building new syntax.

The full operator catalog, with before/after examples and what a survivor
of each one means, is in `docs/guides/operators.md`.

`Engine#analyze` walks only the target `DefNode`'s body. It stops at
nested `def`s, since those are separate subjects. It asks every operator
whether it applies to each node, then builds one `Mutation` per surviving
edit: the subject, the edit, the original snippet, the 1-based
original-file line, and (critically) the **mutated `def` source**,
re-sliced from the re-parsed mutated file. That last piece is what a fork
will later `eval`.

## 3. Coverage map: instrumented baseline + incremental delta

Before any mutant runs, active_mutator needs to know which RSpec examples
cover which source lines, and it needs proof the suite is green *before*
mutating it (`Baseline`, `lib/active_mutator/baseline.rb`).

**The baseline run** shells out to `bundle exec rspec` in a subprocess,
with `Coverage.start(lines: true)` active before RSpec itself boots
(`baseline_hooks.rb`, loaded via `RUBYOPT=-r<absolute-path>`). It uses
`RUBYOPT`, not `--require`, because `.rspec`'s own requires load app code
before RSpec gets to a command-line `-r`, and `Coverage` misses everything
loaded before `Coverage.start`. An `around(:each)` hook diffs
`Coverage.peek_result` before and after each example and records exactly
the lines whose hit count increased: the lines *this example* newly
covered, not lines an earlier example already covered. It also records
each example's wall time (`Process.clock_gettime`, not
`example.execution_result.run_time`, which stays `nil` until after
`around` hooks finish). A non-green baseline aborts the whole run
(`BaselineFailed`), because mutating a red suite produces meaningless
kill/survive data.

**Cache format v2** stores per-example records as the primary data:
`{example_id => [[abs_path, line], ...]}`, plus per-example times, plus a
digest map of every `{app,lib,spec}/**/*.rb` file, `Gemfile.lock`, and
`.rspec`. It does not store the inverted index. `CoverageMap` derives the
inverted `file:line → [example_ids]` map in memory on load. The cache
itself stays disposable: any structural doubt (wrong version, corrupt
JSON) triggers a full re-run, never a migration.

**Delta refresh** is what makes the dev loop fast. On a digest mismatch,
`BaselineDelta.compute` classifies every changed file and decides a
surgical refresh instead of a full re-run, per file:

| Change | Refresh action |
|---|---|
| Spec file changed/added | Re-run that spec file instrumented; drop its old records; merge the new ones |
| Source file changed | Re-run the examples *currently* covering any line of that file; replace their records |
| Spec file deleted | Drop its records (or a full re-run instead, if it owned none: a support-like file) |
| Source file deleted | Drop it from all records |
| Anything under `spec/support/**`, or a spec file owning no example records | Full re-run. Shared/support code is attributed to the files that *use* it, so there is nothing to surgically re-run |
| Rename, `.rspec`/`Gemfile.lock` change, version mismatch, anything ambiguous | Full re-run (the safe fallback) |

`Baseline#run_partial!` re-invokes `bundle exec rspec` with just the
targeted spec files or example ids, and `merge_partial!` folds the result
into the cached JSON. Both the full and partial write paths go through
`AtomicFile.write`: `flock` on a sidecar lock file, write-to-temp, then
`File.rename`. This means a human and an agent running active_mutator at
the same time in the same repo can't corrupt the cache (or the acceptance
ledger, which uses the same helper).

**The documented blind spot:** "re-run the examples currently covering the
changed file" cannot find an example in an *unchanged* spec file that
only starts covering the changed source *because of* the edit. For
example, a pre-existing shared or parameterized example might now reach a
newly added branch. The delta model has no way to know that example
exists without running it, since it wasn't in the set of examples that
used to cover anything nearby. The result is a false `uncovered` or
`survived` status on such lines, until the next full baseline runs.

**Recovery:** `--force-baseline` ignores the cache and always runs a full
instrumented baseline. This is why the CI recipe (see the README) runs it
nightly. The incremental path is correct for the common case and is
cheap, but it is not a soundness guarantee on its own. Nightly
`--force-baseline` closes that gap. `docs/skills/mutation-check.md` also
tells an agent: if a survivor's coverage looks implausibly thin for a line
you know is tested, re-run once with `--force-baseline` before writing new
tests.

## 4. The fork pipeline

Each mutant runs in its own forked process. Getting this fast and correct
on a Rails app (not just a gem) is most of the design.

**Parent preload, once:**
1. `Runner#preload!` boots the app in `RAILS_ENV=test` (or whatever
   `--require` files are configured) and, for a Rails app, eager-loads it.
2. `Runner#preload_spec_helper!` additionally requires the project's
   `spec/rails_helper.rb` or `spec/spec_helper.rb` **in the parent**
   (auto-detected, overridable with `--preload-helper`/`--no-preload-helper`).
   Every fork inherits this via copy-on-write, so RSpec-rails glue,
   `spec/support/**`, and factory loading are paid for once, not once per
   mutant. A worker's own `--require spec_helper` (from `.rspec`) becomes
   a no-op, because the file is already in `$LOADED_FEATURES`.
3. **SimpleCov disarm.** Projects commonly call `SimpleCov.start` in the
   helper. Left alone, its `at_exit` would fire once at the end of the
   *entire mutation run*. That would overwrite the project's real
   coverage data with noise, and a `minimum_coverage` setting would
   `exit 1` for a reason that has nothing to do with mutation results.
   After preload, if `defined?(SimpleCov)`, the Runner neutralizes it with
   `SimpleCov.at_exit {}`. Every active_mutator process (the parent, the
   baseline subprocess, and every fork) also sets
   `ENV["ACTIVE_MUTATOR"] = "1"`. This lets a project's own spec helper
   guard its coverage or profiling setup the same way:
   `SimpleCov.start unless ENV["ACTIVE_MUTATOR"]`.

**World-group filtering (the correctness-critical part).** Preloading the
helper in the parent has a side effect. `spec/support/**` files often call
`RSpec.describe` at load time (shared top-level groups). That registers
them in `RSpec.world`, in the parent process, which every fork inherits.
If a worker naively ran "everything in `RSpec.world`," those leaked groups
would run *in addition to* the mutant's actual covering examples, in
every single fork. A failure in one of them would report as a false
`killed` for every mutant, silently inflating the score across the board.
`Worker#covering_groups` (`lib/active_mutator/worker.rb`) filters
`RSpec.world.ordered_example_groups` down to groups whose
`metadata[:absolute_file_path]` matches one of this mutant's covering spec
files. Nothing else runs. (`RSpec.shared_examples` is a separate registry
and is unaffected either way.)

**Per-fork worker lifecycle** (`Worker#run`):
1. `runner.setup`: RSpec loads the covering spec files. This is also what
   loads the application for any project that *isn't* preloaded in the
   parent (plain gems with no `config/environment.rb`). That's why
   insertion cannot happen first: inserting into a not-yet-defined
   constant raises `NameError`, and loading app code after insertion would
   silently overwrite the mutation with the original method.
2. `Inserter#insert`: `class_eval`s (or top-level `eval`s) the mutated
   `def` source, at the subject's original file and line (for accurate
   backtraces), redefining the just-loaded method with its mutated body.
3. `after_fork_hygiene`: reseed `srand`, and for Rails apps, clear and
   re-establish `ActiveRecord::Base` connections. Forked child processes
   inherit the parent's file descriptors, including DB sockets, and
   sharing a connection across processes corrupts it.
4. `runner.run_specs(covering_groups)`: run only the filtered groups from
   above, in-process.
5. Emit a JSON status line over the pipe back to the parent and exit.

Fork gives correctness for free. There is no "un-mutate between
mutations" step, because the mutated process is simply thrown away. The
design explicitly rejected persistent, long-lived workers that un-insert
between mutations, because they'd leak memoization, class-level state,
and DB residue across mutations and silently corrupt results. The
isolation guarantee is worth the process-boot cost, and that cost is
exactly what the preload steps above exist to amortize.

## 5. Serial lane for browser-covered mutants

System and feature specs boot a browser and an app server per fork. That
cost cannot be shared across forks, because sockets don't survive `fork`.
Running many of them at once oversubscribes the machine, and that is what
turns honest-but-slow kills into false timeouts.

`Scheduler#run` (`lib/active_mutator/scheduler.rb`) splits work into two
lanes and runs them as two sequential passes that feed one result stream:
- `:parallel`: the default lane, with `--jobs` concurrent forks.
- `:serial`: any mutant whose covering examples include a path matching
  `--serial-pattern` (default `spec/system/`, `spec/features/`). These run
  one at a time.

The lane assignment is deliberately "greedy toward correctness, not
speed." A mutant covered by *both* a unit spec and a browser spec goes
entirely into the serial lane, and still runs its browser examples.
Dropping the browser examples to keep it in the parallel lane would be
faster, but unsound: if only the browser example actually kills that
mutant, dropping it manufactures a false `survived`.

## 6. Timeout budget

Per-mutant timeout is `sum(baseline example times for its covering
examples) × --timeout-factor + --timeout-floor` (default factor `8`, floor
`10`s), plus `--browser-boot-seconds` (default `15`) for serial-lane items.
The factor absorbs slowdown from N forks sharing a machine. The floor
absorbs the fork's own boot cost (spec-file loading plus suite hooks; the
helper itself is already preloaded).

The **parent**, not the worker, enforces the deadline
(`Scheduler#reap`), using `Process.kill("KILL", -pid)` against the whole
process group. Each fork calls `Process.setpgid(0, 0)`, so a kill also
reaps anything it spawned, such as a browser. This matters for
correctness, not just cleanliness: a worker-side timeout cannot interrupt
every possible infinite loop, since the mutated code itself might be the
thing spinning, with no chance to check a deadline.

## 7. Statuses

| Status | Meaning | Counts toward score? |
|---|---|---|
| `killed` | a covering example failed against the mutant | yes (numerator) |
| `survived` | every covering example passed against the mutant | yes (denominator only) |
| `timeout` | covering examples exceeded the computed budget | yes, as detected (numerator) |
| `accepted` | matched a fingerprint in the acceptance ledger | no (reported, but excluded from the score) |
| `uncovered` | no example covers the mutated line | no (reported loudly as coverage debt) |
| `error` | the worker crashed, or the mutated code raised at `eval`/load time | reported separately, not scored |
| `invalid` | the mutated text failed to re-parse (discarded before scheduling) | no |

`score = (killed + timeout) / (killed + timeout + survived)`. The process
exit code is `1` iff any **unaccepted** survivor exists.

## 8. Acceptance ledger and fingerprints

Since equivalent mutants are undecidable in general (see
`docs/guides/what-is-mutation-testing.md`), active_mutator gives you a
committed, reviewable way to say "this one's fine":
`.active_mutator_accepted.json` at the repo root. It lives deliberately
**outside** the gitignored `.active_mutator/` cache directory, because
acceptance is durable team and CI state, while the cache is not.

A mutant's identity in the ledger is a **fingerprint**
(`lib/active_mutator/fingerprint.rb`): `{file, subject, description,
original_snippet, ordinal}`. Line number is deliberately not part of it,
so an accepted mutant survives the method moving within the file.
`ordinal` is the mutant's position, in source order, among mutants that
share the exact same `(subject, description, original_snippet)`. Without
it, `a > 0 && b > 0` would produce two byte-identical fingerprints for its
two `>` mutants, and accepting one would silently accept both, hiding a
real gap in the other. Reordering statements within a subject invalidates
ordinals. That's acceptable, since it just means re-accepting.

`--accept-survivors` appends the run's current survivor fingerprints to
the ledger (pruning anything that no longer matches any live mutant) and
writes it atomically. The run that accepts still exits `1`; acceptance
takes effect on the *next* run. Every run also warns about **stale**
entries: a ledger fingerprint with no matching current mutant, typically
because the file was renamed or the mutant no longer applies. This is a
nudge to re-accept after a rename, instead of letting dead entries
silently pile up.

## Honest limits

- **Method bodies only.** No class-macro, constant, or DSL-block mutation
  (`validates`, `scope`, `has_many`, etc.). This follows from how subjects
  are found (§1) and inserted (§4); it is not an accident.
- **`class << self` bodies and nested `def`s are invisible** to subject
  discovery (§1).
- **Heredoc strings, and quote-less/interpolated string segments, are not
  mutated** (`Operators::Literal`).
- **RSpec only.** Test selection, worker setup, and the world-group filter
  are all RSpec-API-shaped.
- **The incremental baseline's blind spot** (§3): a newly-covering example
  in an unchanged spec file is missed until the next `--force-baseline`.
- **Equivalent mutants are not detected.** They are only curated against
  by operator design and closed out through the acceptance ledger. Some
  survivor noise is inherent to the technique, not a bug in this tool.
- **Linux/macOS only** (an MRI `fork` is required); no Windows support.

See also: `docs/guides/what-is-mutation-testing.md` for the concepts behind
all of this, `docs/guides/operators.md` for the mutation catalog, and
`docs/skills/mutation-check.md` for the agent-facing workflow that consumes
a run's output.
