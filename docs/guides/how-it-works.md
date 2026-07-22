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
constant_scope, kind, sclass}`) for every `def` it finds, for example
`Billing::Calculator#total` or `Billing::Calculator.build`.

Scope details worth knowing:
- `class << self` bodies inside a constant scope ARE visited: their defs
  become singleton subjects (`Foo.bar`) flagged `sclass`, so insertion
  targets the singleton class. `class << obj` and a top-level
  `class << self` (no constant to hang the method on) are skipped.
- Nested `def`s get no subject of their own: `visit_def_node` does not
  call `super`. Their bodies still mutate — the engine descends into them
  under the OUTER subject, because a directly-inserted nested-def mutant
  would be silently reverted every time the outer method re-runs the
  `def`.
- **Class bodies are subjects too**, for Zeitwerk-shaped files (see §4a).
  A file with exactly one top-level class/module also yields a
  `"<Scope> (class body)"` subject covering its class-level code —
  macros (`validates`, `scope`, `has_many`), constants, and DSL/scope
  lambdas. `SubjectFinder.zeitwerk_shaped?` gates this: multi-constant
  files and core-class reopens get method subjects only, because they have
  no safe remove-and-reload story (issue #32). Class-level statements owned
  by other subjects (`def`s, nested classes/modules, `class << self`) are
  excluded from the class-body subject.

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

`Engine#analyze` walks the target `DefNode`'s body, descending INTO nested
`def`s and mutating their bodies too (they get no subject of their own — see
§1). It asks every operator
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

**The newly-covering-example blind spot (mostly closed since 0.2):** "re-run
the examples currently covering the changed file" cannot, on its own, find
an example in an *unchanged* spec file that only starts covering the changed
source *because of* the edit (a pre-existing shared or parameterized example
that now reaches a newly added branch). The delta model has no way to know
that example exists without running it, since it wasn't in the set of
examples that used to cover anything nearby.

Since 0.2 the delta refresh **also** re-runs unchanged spec files that
*textually reference a constant defined in the changed source file* but
currently contribute zero coverage to it. `DefinedConstants` does a Prism
walk of the changed file and emits the **deepest fully qualified**
class/module names it defines (`Billing::Invoice`, not `Invoice` and not the
bare wrapper `Billing`); `BaselineDelta` word-boundary-matches those names
against every non-covering spec file and re-runs any that hit. If more than
50% of spec files match (a common token slipped through), it degrades to a
full baseline and prints a stderr warning rather than re-running most of the
suite silently. This closes the common case — the flag-flipped branch in an
unchanged spec that names the changed class.

**Residual gap — six cases still missed until the next full baseline**, all
recovered by nightly `--force-baseline`:

1. **Pure indirection** — a spec that newly covers the change but references
   *neither* the constant *nor* the source file textually (it reaches the
   code through an unrelated collaborator). Nothing links it to the edit.
2. **Partially-covering spec files** — a spec file that *already* contributes
   some coverage to the changed file (so it is skipped by the zero-coverage
   candidate rule) but whose *other*, non-covering examples newly start
   covering it. Re-running such files wholesale on every edit would regress
   incremental speed for the common zero-growth case, so it is not done.
3. **Nested constant referenced by bare leaf name only** — a spec that writes
   `Invoice` for `Billing::Invoice`. `DefinedConstants` deliberately never
   emits bare leaves (a common leaf would match half the suite and trip the
   full-run fallback on every edit), so the leaf-only reference is not seen.
4. **Pure namespace wrapper referenced only by the wrapper** — a spec that
   mentions only `Billing` for a change inside `module Billing; class Invoice`.
   Wrapper tokens are never emitted for the same thrash reason.
5. **Top-level `::`-prefixed definitions** (`class ::Foo`) — the emitted slice
   is `::Foo`, and `/\b::Foo\b/` can never match (there is no word boundary
   before `:`), so such files are silently unscanned. See the `TODO` in
   `lib/active_mutator/baseline_delta.rb`.
6. **Value objects assigned to a constant** (`Point = Data.define(...)`,
   `Struct.new(...)`) — these parse as `ConstantWriteNode`, not a
   class/module node, so `DefinedConstants` emits no name and their
   references are never scanned.

**Recovery:** `--force-baseline` ignores the cache and always runs a full
instrumented baseline. This is why the CI recipe (see the README) runs it
nightly. The incremental path is correct for the common case and is
cheap — the constant-reference scan extends that common case — but it is
not a soundness guarantee on its own. Nightly `--force-baseline` closes
every residual gap above. `docs/skills/mutation-check.md` also tells an
agent: if a survivor's coverage looks implausibly thin for a line you know
is tested, re-run once with `--force-baseline` before writing new tests.

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
1. `require` the subject's file: guarantees the target constant is defined
   before insertion, regardless of preload. Preloaded projects
   (Rails/Zeitwerk, or a preloaded spec helper) already have it in
   `$LOADED_FEATURES` so this is a no-op; non-preloaded projects (plain
   gems whose individual spec files require the lib, or
   `--no-preload-helper`) get it loaded here rather than depending on
   spec-load to define it.
2. Insert the mutation — *before* the spec files are loaded. A `def` mutant
   goes through `Inserter#insert`, which `class_eval`s (or top-level
   `eval`s) the mutated `def` source at the subject's original file and
   line (for accurate backtraces), redefining the method *in place* on the
   live class. A class-body mutant goes through `ClosureReload`, which
   `remove_const`s the target and re-`eval`s the mutated whole-file source,
   producing a **new** class object bound to the constant. Insertion must
   precede spec-load because `RSpec.describe SomeClass` binds
   `metadata[:described_class]` to the constant *at load time*: if the
   groups loaded first, a class-body mutant's reload would swap the constant
   to a new object while the already-loaded groups kept pointing at the
   pre-mutation object — exercising unmutated code and falsely surviving.
   Insert first and every group binds to the mutated object.
3. `runner.setup`: RSpec loads the covering spec files (now binding
   `described_class` to the mutated object).
4. `after_fork_hygiene`: reseed `srand`, and for Rails apps, clear and
   re-establish `ActiveRecord::Base` connections. Forked child processes
   inherit the parent's file descriptors, including DB sockets, and
   sharing a connection across processes corrupts it.
5. `runner.run_specs(covering_groups)`: run only the filtered groups from
   above, in-process.
6. Emit a JSON status line over the pipe back to the parent and exit.

Fork gives correctness for free. There is no "un-mutate between
mutations" step, because the mutated process is simply thrown away. The
design explicitly rejected persistent, long-lived workers that un-insert
between mutations, because they'd leak memoization, class-level state,
and DB residue across mutations and silently corrupt results. The
isolation guarantee is worth the process-boot cost, and that cost is
exactly what the preload steps above exist to amortize.

## 4a. Class-level mutation: closure reload

A `def` mutant is inserted by `class_eval`ing the mutated method over the
live class — same object, method redefined in place. **Class-level code
cannot be inserted that way.** Re-running a macro *accumulates* state
rather than replacing it: `class_eval`ing a class body that calls
`validates :name` a second time adds a *second* validator, it does not
swap the mutated one in. So a class-body mutant (`kind: :class_body`) goes
through a different path — `ClosureReload`
(`lib/active_mutator/closure_reload.rb`).

**Remove and re-eval.** `ClosureReload` `remove_const`s the target and
re-evaluates the *whole mutated file*, producing a **new** class object
bound to the constant. But anything already attached to the OLD object
would go stale — a class that `include`s the module, a subclass, an
`extend` site all still point at the pre-remove object. So the reload
computes the object's **closure** and reloads those too, from their
*pristine* sources (only the target file is the mutated source).

**One-pass closure discovery.** `attachers` does a single
`ObjectSpace.each_object(Module)` scan for every module whose `ancestors`
include the target: includers and subclasses carry it directly; `extend`
sites carry it in their singleton class's ancestry, so singleton classes
are mapped back through `attached_object`. Ruby's `ancestors` is
transitive, so one scan already yields every *transitive* attacher — an
includer-of-an-includer carries the target directly too — and no BFS is
needed.

**Dependency-first re-eval.** Members must be re-eval'd before their
dependents or the dependent's file hits a `NameError`. The target is
pinned first (every closure member depends on it), then the rest are
sorted by ascending `ancestors.size` (a superclass before its subclass, an
included module before its includer). Depth is captured while the
constants are still live, since it can't be read after `remove_const`.

**Guards → `skipped`.** Every situation where the reload can't be done
faithfully raises `ClosureReload::Skip`, which the worker reports as
`skipped` (not counted in the score — see §7):
- the closure exceeds `class_level_closure_cap` (default `10`, set from
  config via `ClosureReload.cap`);
- the target constant is defined at a different file than the subject's
  (a **reopened** constant);
- a closure member is an **anonymous** class/module, has **no source
  file** (native or dynamically defined), or its file **defines multiple
  top-level constants** (re-evaling it would re-run macros on constants
  that weren't removed);
- an **object instance** (not a Module) was `extend`ed with the target.

The fork dies after the run, so nothing is restored; there is no
un-reload step.

### The two-phase kill pipeline

Class-level statements execute at **load time**, so line coverage never
attributes any example to them — the naive "examples covering the mutated
line" set would be empty, and every class-body mutant would look
`uncovered`. `Runner#examples_for_mutation` substitutes a broader set for
class-body subjects:

- **Phase 1** runs the mutant against every example that covers **any line
  of the subject's file** (it must have loaded the class) ∪ the examples of
  the **convention spec file** (`app/models/foo.rb` → `spec/models/foo_spec.rb`).
- **Phase 2 (escalation)** runs only if phase 1 declares a *survivor*.
  Before a class-body survivor is final, `escalate_class_body_survivors`
  re-enqueues it against every spec file that **textually references a
  constant the subject's file defines** and that phase 1 didn't already
  run. Matching is textual (a constant in a comment still counts — worst
  case is a wasted run), and unlike the baseline delta there is **no
  fan-out ceiling**: a class-body survivor gets every referencing spec its
  shot. If escalation kills it, the kill wins; if it still survives, the
  result is annotated `escalated (+N spec files)`.

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

With `--adaptive-timeout` (the default), a per-lane `TimeoutCalibrator`
scales the *variable* part of each remaining budget from what workers
actually took. Each lane keeps its own calibrator (parallel and serial
never pool samples). After a warm-up of 5 **killed** forks, the calibrator
takes the median of each sampled fork's utilization — its wall time
against the effective budget it actually ran under — and scales future
budgets toward a target utilization of `0.25`, grow-only: clamped to the
`1`–`4` range, so budgets extend beyond the static value but never fall
below it (timeouts are censored samples — a shrunken budget would have no
recovery signal). Only killed forks are sampled: errors, survivors, and timeouts
never feed the calibrator (a timeout's wall time is an artifact of the
budget, not the honest run cost). The fixed part of the budget (floor plus
browser boot) is never scaled — only the covering-example time is. Whenever
a lane's applied scale changes, the scheduler emits
`active_mutator: adaptive timeout scale (parallel|serial): N.NN` on stderr;
that line is how you see effective budgets, since `--debug-plan`
intentionally keeps printing the static ones. Pass `--no-adaptive-timeout`
to restore the purely static budget.

## 7. Statuses

| Status | Meaning | Counts toward score? |
|---|---|---|
| `killed` | a covering example failed against the mutant | yes (numerator) |
| `survived` | every covering example passed against the mutant | yes (denominator only) |
| `timeout` | covering examples exceeded the computed budget | yes, as detected (numerator) |
| `accepted` | matched a fingerprint in the acceptance ledger | no (reported, but excluded from the score) |
| `uncovered` | no example covers the mutated line | no (reported loudly as coverage debt) |
| `error` | the worker crashed, or the mutated code raised at `eval`/load time | reported separately, not scored |
| `skipped` | a class-body mutant whose closure couldn't be reloaded faithfully (cap exceeded, reopened constant, anonymous/native/multi-constant attacher — see §4a) | no (listed under "Skipped mutants", excluded from the score; progress char `-`, Stryker `Ignored`) |
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

- **Class-body mutation requires a Zeitwerk-shaped file** — exactly one
  top-level class/module (§1). Multi-constant files and core-class
  monkey-patches/reopens get method subjects only, not a class-body subject
  (issue #32); their method bodies are still mutated.
- **Most code inside blocks is not mutated.** `ActiveSupport::Concern` DSL
  blocks — `included`/`prepended`/`class_methods do … end` — ARE mutated,
  since their bodies re-run as class-level code in the includer (issue #31).
  Every *other* block (`has_many :x do … end` and any other `do … end`/`{ … }`
  body) is pruned, because its run-time context is unknown and mutating it
  risks false survivors. Note that a concern-block line executing ONLY at
  include/load time (a macro, a bare constant) gets no per-example coverage,
  so its mutant lands `uncovered`; lines run when a method is *called* from a
  spec are covered and killable.
- **Whole-file re-eval re-runs class-body side effects.** A closure reload
  re-evaluates the target *and every attacher's* class body from source, so
  non-idempotent load-time side effects run again — self-registration into a
  global registry, `DescendantsTracker`-style hooks, observer wiring. A spec
  asserting a count of such registrations can see it doubled (false kill) or
  masked (false survival). Inherent to remove-and-reload.
- **Constants captured by value go stale after a closure reload.** A
  reference holding the target by value rather than by ancestry — an alias
  (`ALIAS = SomeClass`), a registry the class was pushed into, a memoized
  instance, a class var captured at load — keeps pointing at the pre-reload
  object, and can produce false survivors. `refine`-based modules are
  anonymous and aren't discovered/reloaded at all (§4a).
- **Inter-attacher `extend` ordering (rare).** The re-eval order pins the
  target first, then sorts the rest by instance-ancestor depth. An
  `extend` relationship *between two non-target attachers* can still
  re-eval out of order; a full topological sort is deliberately not
  attempted (see the `ClosureReload` class comment).
- **`class << obj` and top-level `class << self` are invisible** to
  subject discovery; `class << self` inside a class/module IS mutated (§1).
  Nested `def`s mutate only via their enclosing method's subject (§1).
- **Interpolated heredocs and quote-less/interpolated string segments are
  not mutated** (`Operators::Literal`); plain heredoc bodies are emptied.
- **RSpec only.** Test selection, worker setup, and the world-group filter
  are all RSpec-API-shaped.
- **The incremental baseline's residual blind spot** (§3): constant-reference
  detection (since 0.2) re-runs unchanged spec files that name the changed
  class, so the common newly-covering-example case is caught; a handful of
  residual cases (pure indirection, partially-covering files, leaf-only or
  wrapper-only references, `class ::Foo`, `Data.define`/`Struct.new` value
  objects) are still missed until the next `--force-baseline`.
- **Equivalent mutants are not detected.** They are only curated against
  by operator design and closed out through the acceptance ledger. Some
  survivor noise is inherent to the technique, not a bug in this tool.
- **Linux/macOS only** (an MRI `fork` is required); no Windows support.

See also: `docs/guides/what-is-mutation-testing.md` for the concepts behind
all of this, `docs/guides/operators.md` for the mutation catalog, and
`docs/skills/mutation-check.md` for the agent-facing workflow that consumes
a run's output.
