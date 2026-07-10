# What is mutation testing?

## Coverage measures execution, not assertion

Line and branch coverage answer one question: *did any test run this code?*
They cannot answer the question that actually matters: *would a test
**notice** if this code were wrong?*

```ruby
def discount(total)
  return 0 if total < 100
  total / 10
end

it { expect(Calculator.new.discount(200)).to eq(20) }
```

That one example gives `discount` 100% line coverage. It also passes if
`total < 100` is changed to `total <= 100`, if `100` is changed to `101`, or
if the whole guard is deleted. None of those changes touch the code path
this test exercises. Coverage is green and blind at the same time. A tool
that only measures coverage cannot tell you this. A tool that *mutates the
code and re-runs the tests* can, immediately, with an exact diff.

That is mutation testing. Instead of asking whether a test ran a line, it
asks whether a test's assertions **constrain** what that line is allowed
to do. It is the only class of technique that verifies test *quality*
rather than test *reach*.

## Mechanics: mutants, kill, survive

A **mutant** is the program with one small, syntactically valid change
applied. A comparison operator gets flipped, a literal gets changed, a
boolean condition gets forced, a statement gets deleted. For each mutant,
the tool re-runs the tests that exercise the changed line or lines:

- **Killed**: some test fails against the mutant. Good, the tests
  distinguish correct behavior from this specific wrong behavior.
- **Survived**: every test still passes against the mutant. This is the
  signal. The mutated line changed behavior and nothing noticed. It is a
  precise, machine-verified test gap, not a guess.
- **Timeout**: the mutant ran long enough to be presumed different from the
  original (often an accidentally introduced infinite loop). It is counted
  as detected without needing a failing assertion.

**Mutation score** is:

```
score = (killed + timeout) / (killed + timeout + survived)
```

Mutants that never get a chance to run, because no test covers the mutated
line at all, or because the mutated text doesn't even parse, are tracked
separately (`uncovered`, `invalid`) and excluded from the score. They are
diagnostic, not noise. `uncovered` in particular is a *stronger* signal
than `survived`: it means no test exercises that code at all.

## Equivalent mutants, and why 100% is the wrong target

Some mutants cannot be killed by any test because they don't change
observable behavior. They are semantically **equivalent** to the original.
A classic example: replacing `n + 1` with `n.succ` where `n` is always an
`Integer`. No assertion can distinguish them because there is nothing to
distinguish. Detecting equivalence in general is undecidable (it reduces to
the halting problem), so no mutation tool, this one included, can filter
these out automatically.

This means a mutation score of 100% is not the correct target for most
codebases. It is either unachievable, or achieved by writing tests that
pin down implementation accidents rather than behavior. The correct
target is this: **every survivor has been looked at and is either killed
by a new test, or accepted with a stated reason.**

That is the point of an acceptance ledger (see `docs/guides/how-it-works.md`
for the mechanics). Equivalence is a per-mutant judgment call, made once,
recorded, and reviewed like any other code change, not a threshold to game
by weakening the mutation run. A survivor with no recorded reason is an
open question. A survivor with a one-sentence equivalence argument attached
is a closed one. The score trends toward 100% but is not required to hit
it. Ledger entries are the honest way to close the remaining gap.

## Further reading

- DeMillo, Lipton, Sayward, ["Hints on Test Data Selection: Help for the
  Practicing Programmer"](https://doi.org/10.1109/C-M.1978.218136), *IEEE
  Computer*, 1978. This is the origin paper, source of the "competent
  programmer" and "coupling effect" hypotheses that the whole technique
  rests on.
- Jia & Harman, ["An Analysis and Survey of the Development of Mutation
  Testing"](https://doi.org/10.1109/TSE.2010.62), *IEEE Transactions on
  Software Engineering*, 2011. This is the field's most cited survey.
- Petrović & Ivanković, ["State of Mutation Testing at
  Google"](https://doi.org/10.1145/3183519.3183521), ICSE-SEIP 2018. This
  paper covers what it takes to run mutation testing at scale in a real
  engineering org (diff-scoped mutants, budget limits, developer-facing
  survivors).
- Papadakis, Kintis, Zhang, Jia, Le Traon, Harman, ["Mutation Testing
  Advances: An Analysis and
  Survey"](https://doi.org/10.1016/bs.adcom.2019.04.001), 2019. This is a
  modern follow-up survey covering equivalent-mutant handling,
  test-selection strategies, and tool design trade-offs.
- [PIT](https://pitest.org): the standard mutation-testing tool for the
  JVM, and a useful reference point for coverage-guided test selection at
  scale.
- [Stryker](https://stryker-mutator.io): mutation testing across
  JavaScript/TypeScript, .NET, and Scala. Its handbook is a good practical
  treatment of survivor triage.
- [cargo-mutants](https://mutants.rs): mutation testing for Rust. Its book
  documents timeout-budget and "unviable mutant" handling that parallels
  this gem's `timeout`/`invalid` statuses.

See also `docs/guides/how-it-works.md` for how active_mutator implements
mutant generation, test selection, and the kill pipeline, and
`docs/guides/operators.md` for the exact catalog of mutations it applies.
