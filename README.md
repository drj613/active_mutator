# active_mutator

[![Gem Version](https://badge.fury.io/rb/active_mutator.svg)](https://rubygems.org/gems/active_mutator)

Mutation testing for Ruby, built on [Prism](https://github.com/ruby/prism).
Open source, RSpec-integrated, Rails-first. Available on
[RubyGems](https://rubygems.org/gems/active_mutator).

active_mutator mutates your code one small change at a time (`>` becomes `>=`,
`&&` becomes `||`, a statement gets deleted, a condition gets forced, and so
on). It runs exactly the examples that cover the mutated line, and reports
every mutant your suite fails to kill. A surviving mutant is a behavior
change no test notices: a precise, machine-verified test gap.

## A surviving mutant, in one example

```ruby
def discount(total)
  return 0 if total < 100
  total / 10
end
```

```ruby
it { expect(calc.discount(50)).to eq(0) }
it { expect(calc.discount(200)).to eq(20) }
```

Both examples pass. Line coverage on `discount` is 100%. Run active_mutator
and one mutant survives anyway:

```
Surviving mutants:

  Calculator#discount (lib/calculator.rb:11)
    replace `<` with `<=`
    - total < 100
    + total <= 100
```

Nothing in the test suite calls `discount(100)`, the one input where `<`
and `<=` disagree. The tests pass, and coverage is green. But the boundary
is still unverified. That gap is invisible to coverage and obvious to
mutation testing. Add `it { expect(calc.discount(100)).to eq(0) }` and the
mutant is killed.

## What is mutation testing?

Coverage answers "did a test run this line?" Mutation testing answers "would
a test *notice* if this line were wrong?" That is a different, and usually
more useful, question.

active_mutator applies one small, syntactically valid change to your code
(a "mutant") and re-runs only the examples that cover it. If a test fails,
the mutant is **killed**: your tests correctly reject that wrong behavior.
If every covering test still passes, the mutant **survived**: something
changed and nothing noticed. A survivor is not a hypothetical. It is the
exact line, the exact before and after diff, and proof that no assertion
depends on the difference.

Mutation score is `(killed + timeout) / (killed + timeout + survived)`.
100% is usually not the right target. Some mutants are behaviorally
*equivalent* to the original and can never be killed by any test. That is
why active_mutator has a committed acceptance ledger. It lets you close
survivors out with a stated reason instead of chasing an unreachable score.

Full primer, including the origin of the technique and further reading:
**[`docs/guides/what-is-mutation-testing.md`](docs/guides/what-is-mutation-testing.md)**.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "active_mutator"
end
```

Requires Ruby 3.2 or later, RSpec, and a green suite. Linux/macOS (MRI fork).

## Quick start

```bash
bundle install
bundle exec active_mutator app/models/calculator.rb
```

The first run performs an instrumented baseline of your suite to build the
coverage map. The map is cached in `.active_mutator/` and refreshed
incrementally after that (see
[`docs/guides/how-it-works.md`](docs/guides/how-it-works.md)).
Then each mutant runs in its own fork against only its covering examples.

### Reading the output

```
$ bundle exec active_mutator app/models/calculator.rb

.....S..T...U..A....

killed: 14
survived: 1
timeout: 1
error: 0
uncovered: 1
accepted: 1
invalid (discarded): 2
Mutation score: 93.8%

Surviving mutants:

  Calculator#discount (app/models/calculator.rb:9)
    replace `<` with `<=`
    - total < 100
    + total <= 100
```

Each character on the progress line is one mutant, printed as it finishes:

| Char | Status | Meaning |
|---|---|---|
| `.` | `killed` | a covering test failed. Good, the mutant is dead |
| `S` | `survived` | every covering test passed. This is a test gap |
| `T` | `timeout` | ran past its time budget. Counted as detected (likely an infinite loop) |
| `E` | `error` | the worker crashed, or the mutated code raised outside a test assertion |
| `U` | `uncovered` | no test executes the mutated line at all. This is coverage debt, worse than a survivor |
| `A` | `accepted` | matches a known-equivalent entry in the acceptance ledger. Excluded from the score |

`invalid` mutants (edits that don't even re-parse as valid Ruby) are
discarded before scheduling and reported as a count only. Exit code is `1`
if unaccepted survivors exist, `0` otherwise, including when there are
only `uncovered`, `accepted`, or `error` results.

## How it works, compactly

1. **Subject discovery**: a Prism visitor finds every method (`def`) in
   your target files.
2. **Source-span edits**: each operator emits byte-range text edits
   against the original file, not a rewritten AST. Every mutant is
   re-parsed with Prism and discarded (`invalid`) if the edit produced
   something that doesn't parse. No unparser is ever built or maintained.
3. **Coverage-mapped test selection**: one instrumented baseline run maps
   every source line to the examples that cover it. Incremental runs
   refresh only what changed instead of re-running the whole suite.
4. **Fork-per-mutant kill runs**: the parent preloads your app and spec
   helper once. Each mutant is inserted and exercised in its own fork
   against just its covering examples, so results can't bleed state
   between mutants.

Full architecture, including the coverage-cache format, the fork pipeline,
the serial lane for browser specs, timeout budgets, and every status, is in
**[`docs/guides/how-it-works.md`](docs/guides/how-it-works.md)**.

## Usage

```bash
active_mutator                          # mutate app/ and lib/, full run
active_mutator app/models               # scope by path
active_mutator --changed                # uncommitted work only (dev loop)
active_mutator --since origin/main      # PR scope (CI)
active_mutator --subject 'Foo::Bar#baz' # one method
active_mutator --exclude 'lib/generated' # skip a subtree (repeatable)
```

`--subject` also takes broader expressions: `Foo::Bar` (all methods of
that constant), `Foo::Bar*` (namespace prefix), `Foo::Bar#*` (instance
methods only), `Foo::Bar.*` (singleton methods only).

`--exclude PAT` is a glob relative to the project root, applied during
subject discovery, and gitignore-like: `lib/generated`, `lib/generated/`,
and `lib/generated/**` all exclude the whole subtree. File globs like
`**/legacy/*` work too.

Skip a single method by putting `# active_mutator:skip` on the line above
its `def`:

```ruby
# active_mutator:skip
def legacy_delegator
  target.call
end
```

Statuses: `killed` (test failed, this is good), `survived` (test gap),
`timeout` (counts as detected), `uncovered` (no covering example, this is
coverage debt), `accepted` (known-equivalent, see ledger), `error`,
`invalid` (discarded).
Exit code 1 if unaccepted survivors exist.

Score = (killed + timeout) / (killed + timeout + survived).

## The dev loop

TDD until green, then verify the tests constrain the behavior:

```bash
bundle exec active_mutator --changed --format json
```

Kill survivors by writing the missing tests. For genuine equivalent mutants:

```bash
bundle exec active_mutator --changed --accept-survivors   # records to ledger
git add .active_mutator_accepted.json                     # committed state
```

Acceptance takes effect on the next run. The accepting run still exits 1.
Agent workflow: see [`docs/skills/mutation-check.md`](docs/skills/mutation-check.md).

## CI recipe

- Per-PR: `active_mutator --since origin/main` (minutes)
- Nightly: `active_mutator --force-baseline` (full run; also recovers the
  incremental baseline's newly-covering-example blind spot)

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--jobs N` | half the cores | fork-pool width |
| `--changed` | none | mutate uncommitted + untracked work |
| `--since REF` | none | mutate methods changed since REF |
| `--subject EXPR` | none | subject expression, e.g. `Foo#bar`, `Foo::Bar`, `Foo::Bar*`, `Foo#*`, `Foo.*` |
| `--exclude PAT` | none | skip files matching glob during subject discovery (repeatable, gitignore-like) |
| `--max-mutants N` | none | deterministic sample of the first N mutants (quick smoke run on huge scopes) |
| `--debug-plan` | off | print planned mutants as JSON and exit without running |
| `--format terminal\|json` | terminal | report format |
| `--accept-survivors` | off | record survivors to the acceptance ledger |
| `--force-baseline` | off | ignore cached coverage map |
| `--preload-helper FILE` / `--no-preload-helper` | auto-detect | parent spec-helper preload |
| `--serial-pattern PAT` | `spec/system/`, `spec/features/` | covering-path prefixes forced serial |
| `--browser-boot-seconds S` | 15 | serial-lane timeout bump |
| `--timeout-factor F` / `--timeout-floor S` | 8 / 10 | mutation timeout budget |
| `--require FILE` | none | preload files (repeatable) |

`--debug-plan` prints the planned mutant list as one JSON document
(`{"planned": [...], "pre_resolved": {...}}`) and exits without running
anything. A coverage baseline is still built or loaded, since timeouts
and covering examples come from it.

Every active_mutator process sets `ENV["ACTIVE_MUTATOR"] = "1"`. Use it to
guard SimpleCov or other tooling in your spec helper:

```ruby
SimpleCov.start "rails" unless ENV["ACTIVE_MUTATOR"]
```

## Known limits (v1.1)

Method bodies only (no class-macro/constant mutation). RSpec only.
Heredoc strings are not mutated. `class << self` bodies and nested defs
are skipped. The incremental baseline can miss examples that only cover
changed code after the change (nightly `--force-baseline` recovers).

## Guides

- [What is mutation testing?](docs/guides/what-is-mutation-testing.md):
  the concepts. Kill/survive, score, equivalent mutants, further reading.
- [How it works](docs/guides/how-it-works.md): architecture. Subject
  discovery, source-span edits, the coverage map, the fork pipeline, and
  honest limits.
- [Operator reference](docs/guides/operators.md): every mutation
  active_mutator can generate, with before/after examples and what a
  survivor of each one means.
- [Mutation-check skill](docs/skills/mutation-check.md): the agent-facing
  workflow. Run, read survivors, strengthen tests, or accept with a reason.

## Contributing

Issues and pull requests welcome. Run `bundle exec rspec` before sending a
change. Also run `bundle exec active_mutator --changed` on your own diff
before sending a change that touches `lib/`. This is a good idea for the
same reason you'd want it run on any other codebase.

## License

[MIT](LICENSE).
