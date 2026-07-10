# Operator reference

Every mutation active_mutator can generate comes from one of the operators
below. Each operator is a pure function: `edits(node) -> [Edit]` over a
single Prism AST node (`lib/active_mutator/operators/*.rb`). The engine
walks every node in a method body and asks each operator whether it
applies. See `docs/guides/how-it-works.md` for the walk and validity gate.

An operator's mutants only matter if they can be killed. For each operator
below, you'll find: what it targets, the exact edit(s) it emits, a
concrete example, and what a **survivor** of that mutant tells you about
your tests.

## ConditionalBoundary

**Targets:** a comparison call (`>`, `>=`, `<`, `<=`) with a receiver and
exactly one argument. For example, `a > b`, not a bare `>` symbol.

**Edit:** swap the operator for its boundary-adjacent partner:
`>` ↔ `>=`, `<` ↔ `<=`.

```ruby
# before
total < 100
# after
total <= 100
```

**A survivor means:** no test exercises the exact boundary value. If
`age >= 18` survives being mutated to `age > 18`, no test calls the method
with `age == 18`. That's the one input where the two conditions disagree.

## ConditionForcing

**Targets:** the predicate of an `if` or `unless`.

**Edit:** replace the predicate outright with the literal `true` or `false`
(both, unless the predicate is already textually that literal; no-op edits
are never emitted).

```ruby
# before
if age >= 18
  adult_price
else
  child_price
end

# after (forced true)
if true
  adult_price
else
  child_price
end

# after (forced false)
if false
  adult_price
else
  child_price
end
```

**A survivor means:** the branch never taken by any test has no observable
effect, or both branches produce results your tests treat as equivalent.
Forcing the condition is the bluntest possible mutation of a conditional.
If this survives, the conditional itself is close to untested, not just one
comparison operator inside it.

## LogicalOperator

**Targets:** `&&` (`AndNode`) and `||` (`OrNode`).

**Edits (three per node):**
1. Swap the operator (`&&` → `||`, `||` → `&&`).
2. Keep only the left operand (drop the right operand and the operator
   entirely).
3. Keep only the right operand (drop the left operand and the operator).

```ruby
# before
valid? && in_stock?

# after (operator swap)
valid? || in_stock?
# after (left only)
valid?
# after (right only)
in_stock?
```

**A survivor means:** your tests never exercise a case where the two
operands disagree. For the operator swap: no test has `valid?` true and
`in_stock?` false (or vice versa) with an assertion on the outcome. For
the operand-drop edits: no test's result actually depends on both operands.
One of them is decorative as far as the suite can tell.

## Literal

**Targets:** integer literals, string literals, and `true`/`false`
literals.

**Edits:**
- **Integers:** replace with `0` and with `value + 1` (each only if
  different from the original value; a literal `0` only gets the `+1`
  edit).
- **Strings:** a non-empty string literal is replaced with `""`. An empty
  string literal is replaced with `"active_mutator"`. Heredocs and
  quote-less parts (string interpolation segments) are not mutated. This is
  a documented v1 limit.
- **Booleans:** `true` ↔ `false`.

```ruby
# before
total / 10
# after
total / 0        # and: total / 11

# before
name = "default"
# after
name = ""

# before
enabled = true
# after
enabled = false
```

**A survivor means:** no test pins down that exact value. For the integer
case specifically, no test asserts a *computed* result that depends on
the constant (as opposed to just checking truthiness or presence). For the
empty-string case, no test distinguishes "some default text" from "no
text at all."

## StatementDeletion

**Targets:** any `StatementsNode` (a method body or block body) with **two
or more** statements. Single-statement bodies are left alone. Deleting the
only statement in a method collapses it to an implicit `nil` return. That
really tests "does this method return nil" rather than isolating one
statement's effect, and other operators already cover that case more
precisely by targeting the statement's content directly.

**Edit:** for each statement in the body, one mutant that deletes just that
statement (replaces it with an empty string), leaving the others intact.

```ruby
# before
def apply_discount(total)
  log_discount_applied(total)
  total - discount(total)
end

# after (mutant deletes line 1)
def apply_discount(total)

  total - discount(total)
end
```

**A survivor means:** the deleted statement has no effect any test checks
for. Classic candidates: logging, memoization writes, cache invalidation,
or a mutation of state that a later statement doesn't read from in a way
the test observes. If a return-value statement gets deleted and survives,
the method's return value isn't asserted at all.

## EarlyReturn

**Targets:** a `return` with an explicit value (bare `return` is not
mutated).

**Edits:**
1. **Unwrap:** replace `return value` with just `value` (drops the early
   exit; execution falls through to whatever comes after).
2. **Return nil instead:** replace `return value` with `return nil`
   (skipped if `value` is already the literal `nil`, since that edit would
   be a no-op).

```ruby
def discount(total)
  return 0 if total < 100
  total / 10
end

# after (unwrap: mutant no longer exits early)
def discount(total)
  0 if total < 100
  total / 10
end

# after (return nil instead)
def discount(total)
  return nil if total < 100
  total / 10
end
```

**A survivor of the unwrap mutant means:** no test would notice if the
method kept running past this point. The code after the early return has
no observable effect that this input path should have skipped. **A
survivor of the return-nil mutant means:** no test asserts on the actual
*value* returned on this path. It only checks that the method returned, or
that some side effect happened.

## CallSwap

**Targets:** a method call with an explicit receiver, where the method
name is a key in the swap table below.

**Edit:** replace the method name with its paired name. Most pairs are
bidirectional. `.map` → `.each` is deliberately **one-directional**. The
reverse (`.each` → `.map`) is usually an equivalent mutant when the code
discards the mapped return value, so it's excluded from the catalog to
avoid manufacturing unkillable noise.

| Call | Swapped to |
|---|---|
| `.map` | `.each` (one-directional) |
| `.select` | `.reject` |
| `.reject` | `.select` |
| `.min` | `.max` |
| `.max` | `.min` |
| `.first` | `.last` |
| `.last` | `.first` |
| `.any?` | `.none?` |
| `.none?` | `.any?` |
| `.present?` | `.blank?` *(Rails-aware)* |
| `.blank?` | `.present?` *(Rails-aware)* |
| `.save` | `.save!` *(Rails-aware)* |
| `.save!` | `.save` *(Rails-aware)* |

```ruby
# before
active = users.select(&:active?)
# after
active = users.reject(&:active?)

# before
record.present? ? render_record(record) : render_blank
# after
record.blank? ? render_record(record) : render_blank

# before
resource.save
# after
resource.save!
```

**A survivor means**, per family:
- `map`/`each`: nothing asserts on the transformed collection's contents.
  Tests only check side effects performed while iterating.
- `select`/`reject`, `min`/`max`, `first`/`last`, `any?`/`none?`: no test
  distinguishes the two possible results. The assertion is too loose
  (for example, "returns something" instead of "returns *this*").
- `present?`/`blank?`: no test covers both the presence and the absence
  path with distinct expected outcomes.
- `save`/`save!`: no test exercises the failure path. `save` returns
  `false` on a validation failure; `save!` raises an error instead. If
  swapping them survives, no test causes a validation failure here (or the
  failure path isn't checked). This is a common real-world gap, since teams
  usually only test the happy path.

## NegationRemoval

**Targets:** `!x` (Prism desugars this to a `CallNode` named `!` with `x`
as the receiver).

**Edit:** replace the whole negation with the un-negated receiver.

```ruby
# before
skip_validation? unless disabled?
# before (the negation itself)
!disabled?
# after
disabled?
```

**A survivor means:** no test exercises both truth values of the negated
expression with a distinct, asserted outcome. In other words, the branch
guarded by the negation runs the same way whether or not the negation is
actually applied.

---

See `docs/guides/how-it-works.md` for how these edits are generated,
validated, and turned into runnable mutants, and
`docs/guides/what-is-mutation-testing.md` for how to read a survivor once
you have one.
