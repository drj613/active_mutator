# active_mutator

Mutation testing for Ruby, built on [Prism](https://github.com/ruby/prism).
Open source, RSpec-integrated, Rails-first.

active_mutator mutates your code one small change at a time (`>` → `>=`,
`&&` → `||`, delete a statement, force a condition…), runs exactly the
examples that cover the mutated line, and reports every mutant your suite
fails to kill. A surviving mutant is a behavior change no test notices —
a precise, machine-verified test gap.

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

Nothing in the test suite calls `discount(100)` — the one input where `<`
and `<=` disagree. The tests pass, coverage is green, and the boundary is
still unverified. That gap is invisible to coverage and obvious to
mutation testing. Add `it { expect(calc.discount(100)).to eq(0) }` and the
mutant is killed.

## What is mutation testing?

Coverage answers "did a test run this line?" Mutation testing answers "would
a test *notice* if this line were wrong?" — a materially different, and
usually more useful, question.

active_mutator applies one small, syntactically valid change to your code
(a "mutant") and re-runs only the examples that cover it. If a test fails,
the mutant is **killed**: your tests correctly reject that wrong behavior.
If every covering test still passes, the mutant **survived**: something
changed and nothing noticed. A survivor is not a hypothetical — it's the
exact line, the exact before/after diff, and proof that no assertion
depends on the difference.

Mutation score is `(killed + timeout) / (killed + timeout + survived)`.
100% is usually not the right target — some mutants are behaviorally
*equivalent* to the original and can never be killed by any test — which is
why active_mutator has a committed acceptance ledger for closing survivors
out with a stated reason instead of chasing an unreachable score.

Full primer, including the origin of the technique and further reading:
**[`docs/guides/what-is-mutation-testing.md`](docs/guides/what-is-mutation-testing.md)**.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "active_mutator"
end
```

Requires Ruby ≥ 3.2, RSpec, and a green suite. Linux/macOS (MRI fork).

## Quick start

```bash
bundle install
bundle exec active_mutator app/models/calculator.rb
```

First run performs an instrumented baseline of your suite to build the
coverage map (cached in `.active_mutator/`, refreshed incrementally after
that — see [`docs/guides/how-it-works.md`](docs/guides/how-it-works.md)).
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
| `.` | `killed` | a covering test failed — good, the mutant is dead |
| `S` | `survived` | every covering test passed — a test gap |
| `T` | `timeout` | ran past its time budget — counted as detected (likely an infinite loop) |
| `E` | `error` | the worker crashed, or the mutated code raised outside a test assertion |
| `U` | `uncovered` | no test executes the mutated line at all — coverage debt, worse than a survivor |
| `A` | `accepted` | matches a known-equivalent entry in the acceptance ledger — excluded from the score |

`invalid` mutants (edits that don't even re-parse as valid Ruby) are
discarded before scheduling and reported as a count only. Exit code is `1`
iff unaccepted survivors exist — `0` otherwise, including when there are
only `uncovered`/`accepted`/`error` results.

## How it works, compactly

1. **Subject discovery** — a Prism visitor finds every method (`def`) in
   your target files.
2. **Source-span edits** — each operator emits byte-range text edits
   against the original file, not a rewritten AST; every mutant is
   re-parsed with Prism and discarded (`invalid`) if the edit produced
   something that doesn't parse. No unparser is ever built or maintained.
3. **Coverage-mapped test selection** — one instrumented baseline run maps
   every source line to the examples that cover it; incremental runs
   refresh only what changed instead of re-running the whole suite.
4. **Fork-per-mutant kill runs** — the parent preloads your app and spec
   helper once; each mutant is inserted and exercised in its own fork
   against just its covering examples, so results can't bleed state
   between mutants.

Full architecture, including the coverage-cache format, the fork pipeline,
the serial lane for browser specs, timeout budgets, and every status —
**[`docs/guides/how-it-works.md`](docs/guides/how-it-works.md)**.

## Usage

```bash
active_mutator                          # mutate app/ and lib/, full run
active_mutator app/models               # scope by path
active_mutator --changed                # uncommitted work only (dev loop)
active_mutator --since origin/main      # PR scope (CI)
active_mutator --subject 'Foo::Bar#baz' # one method
```

Statuses: `killed` (test failed — good), `survived` (test gap), `timeout`
(counts as detected), `uncovered` (no covering example — coverage debt),
`accepted` (known-equivalent, see ledger), `error`, `invalid` (discarded).
Exit code 1 iff unaccepted survivors exist.

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

Acceptance takes effect on the NEXT run (the accepting run still exits 1).
Agent workflow: see [`docs/skills/mutation-check.md`](docs/skills/mutation-check.md).

## CI recipe

- Per-PR: `active_mutator --since origin/main` (minutes)
- Nightly: `active_mutator --force-baseline` (full run; also recovers the
  incremental baseline's newly-covering-example blind spot)

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--jobs N` | half the cores | fork-pool width |
| `--changed` | — | mutate uncommitted + untracked work |
| `--since REF` | — | mutate methods changed since REF |
| `--subject NAME` | — | one subject, e.g. `Foo#bar` |
| `--format terminal\|json` | terminal | report format |
| `--accept-survivors` | off | record survivors to the acceptance ledger |
| `--force-baseline` | off | ignore cached coverage map |
| `--preload-helper FILE` / `--no-preload-helper` | auto-detect | parent spec-helper preload |
| `--serial-pattern PAT` | `spec/system/`, `spec/features/` | covering-path prefixes forced serial |
| `--browser-boot-seconds S` | 15 | serial-lane timeout bump |
| `--timeout-factor F` / `--timeout-floor S` | 8 / 10 | mutation timeout budget |
| `--require FILE` | — | preload files (repeatable) |

Every active_mutator process sets `ENV["ACTIVE_MUTATOR"] = "1"` — use it to
guard SimpleCov or other tooling in your spec helper:

```ruby
SimpleCov.start "rails" unless ENV["ACTIVE_MUTATOR"]
```

## Known limits (v1.1)

Method bodies only (no class-macro/constant mutation) · RSpec only ·
heredoc strings not mutated · `class << self` bodies and nested defs
skipped · incremental baseline can miss examples that only cover changed
code after the change (nightly `--force-baseline` recovers).

## Guides

- [What is mutation testing?](docs/guides/what-is-mutation-testing.md) —
  the concepts: kill/survive, score, equivalent mutants, further reading.
- [How it works](docs/guides/how-it-works.md) — architecture: subject
  discovery, source-span edits, the coverage map, the fork pipeline, and
  honest limits.
- [Operator reference](docs/guides/operators.md) — every mutation
  active_mutator can generate, with before/after examples and what a
  survivor of each one means.
- [Mutation-check skill](docs/skills/mutation-check.md) — the agent-facing
  workflow: run, read survivors, strengthen tests, or accept with a reason.

## Contributing

Issues and pull requests welcome. Run `bundle exec rspec` before sending a
change; `bundle exec active_mutator --changed` on your own diff before
sending a change that touches `lib/` is a good idea for the same reason
you'd want it run on any other codebase.

## License

MIT.
