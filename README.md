# active_mutator

Mutation testing for Ruby, built on [Prism](https://github.com/ruby/prism).
Open source, RSpec-integrated, Rails-first.

active_mutator mutates your code one small change at a time (`>` → `>=`,
`&&` → `||`, delete a statement, force a condition…), runs exactly the
examples that cover the mutated line, and reports every mutant your suite
fails to kill. A surviving mutant is a behavior change no test notices —
a precise, machine-verified test gap.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "active_mutator"
end
```

Requires Ruby ≥ 3.2, RSpec, and a green suite. Linux/macOS (MRI fork).

## Usage

```bash
active_mutator                          # mutate app/ and lib/, full run
active_mutator app/models               # scope by path
active_mutator --changed                # uncommitted work only (dev loop)
active_mutator --since origin/main      # PR scope (CI)
active_mutator --subject 'Foo::Bar#baz' # one method
```

First run performs an instrumented baseline of your suite to build the
coverage map (cached in `.active_mutator/`, refreshed incrementally). Then
each mutant runs in its own fork against only its covering examples.

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
Agent workflow: see `docs/skills/mutation-check.md`.

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
guard SimpleCov or other tooling in your spec helper.

## Known limits (v1.1)

Method bodies only (no class-macro/constant mutation) · RSpec only ·
heredoc strings not mutated · `class << self` bodies and nested defs
skipped · incremental baseline can miss examples that only cover changed
code after the change (nightly `--force-baseline` recovers).
