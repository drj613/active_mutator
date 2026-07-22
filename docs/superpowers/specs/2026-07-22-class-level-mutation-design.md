# Class-Level Mutation Design (Issue #2)

**Goal:** Mutate class-level code — Rails macros (`validates`, `scope`,
callbacks), constants, and DSL lambda bodies — which v1 skips entirely
because insertion re-evals a single `def`.

**Approach chosen:** Class-body subjects + whole-file closure reload in the
fork (approach A; macro-registry reset and boot-per-mutant were rejected as
fragile and too slow respectively).

**Primary target:** Rails macros first (user decision). Constants and DSL
blocks come along for free because the same operators walk the same nodes.

## 1. Subject discovery — `:class_body` subjects

`SubjectFinder` emits a second kind of subject: for each class or module
node with a constant scope, one subject with `kind: :class_body` and name
`User (class body)`.

- Byte range: the class-body statements span.
- Mutation-eligible nodes exclude `DefNode` subtrees and nested
  class/module subtrees — those are owned by other subjects.
- Static eligibility gate: the file must be Zeitwerk-shaped — exactly one
  top-level constant defined in the file. Files defining multiple constants
  or reopening core classes get no class-body subject (reported as skipped
  with reason). Follow-up for lifting this: issue #32.
- Empty class bodies (only defs) produce no subject.
- `# active_mutator:skip` on the line above `class`/`module` skips the
  class-body subject, same mechanism as defs.
- Method subjects are unchanged.

## 2. Mutation generation

- Engine adds a class-body walk: for a `:class_body` subject, visit each
  class-body statement and descend into non-def expressions (scope
  lambdas, macro arguments), skipping DefNode/class/module subtrees.
- The full existing operator set (including plugin operators) runs over
  those nodes. Expected high-value mutants:
  - `StatementDeletion`: delete a whole `validates ...` line (keep the
    existing ≥2-statements rule as-is).
  - `Literal`: `presence: true → false`, defaults in macro args.
  - `ConditionForcing` / `ConditionalBoundary` / `CallSwap` /
    `LogicalOperator` / `NegationRemoval`: inside `scope :x, -> { ... }`
    lambdas and `if:` procs.
- Mutant text = the whole original file with the edit spliced (Splicer
  unchanged). Validity gate = Prism reparse of the full file, unchanged.
- `--subject` expressions match class-body subjects by name naturally.
- Deliberate exclusion: block bodies passed to macros
  (`has_many ... do ... end` association extensions) stay unvisited —
  same v1 block rule. Tracked in issue #31.

## 3. Insertion — closure reload in the fork

Anything already attached to the old constant object is stale after
`remove_const` + re-eval: classes that include the module, subclasses of
the class. Instead of skipping those cases, reload them too.

1. In the fork, compute the **reload closure** of the target constant:
   - Includers: one `ObjectSpace.each_object(Module)` scan — every
     module/class (other than the target) whose `ancestors` contains the
     old target object.
   - Subclasses: `target.subclasses`, recursively.
   - Breadth-first: attachers of attachers join the closure.
2. Order the closure dependency-first (target, then attachers, then
   theirs).
3. `remove_const` each member — deepest constant only
   (`Billing::Calculator` → `Billing.send(:remove_const, :Calculator)`) —
   then re-eval files in order via
   `eval(source, TOPLEVEL_BINDING, file, 1)`: **mutated source for the
   target file, pristine source for every other closure member**.
   Re-evaling an includer re-runs `include TheConcern` against the fresh
   module, so `included do ... end` macros land on the fresh class;
   re-evaling a subclass picks up the fresh superclass.
4. Per-member guards (whole closure must pass): Zeitwerk-shaped file,
   constant resolvable, not a core-class reopen. Any failure → the mutant
   is `skipped` with a reason naming the offender.
5. Closure size cap: `class_level_closure_cap` (default 10 files); beyond
   it, skip with reason.

No un-mutate step — the fork dies after the run, as today.

Accepted limit (documented): another class capturing the constant object
itself at boot (`USER_CLASS = User`) holds a stale reference; lazy
name-based resolution (Rails reflections' `class_name.constantize`) is
fine.

## 4. Kill pipeline — two-phase escalation

Class-body lines execute at boot, so the baseline coverage map has no
covering examples for them. Substitute:

- **Phase 1 (fast set):** spec files covering any line of the subject's
  file in the baseline coverage map, ∪ the convention spec file
  (`app/models/user.rb` → `spec/models/user_spec.rb`,
  `lib/x/y.rb` → `spec/x/y_spec.rb`) when it exists.
- **Phase 2 (escalation, only on phase-1 survival):** all spec files
  referencing the constant (phase-4 `DefinedConstants` reference-scan
  machinery), minus phase-1 files. The mutant is re-enqueued as a new work
  item with that set. A survivor is only declared after phase 2 also
  passes; the reporter annotates it `survived (escalated, N extra files)`.
- Both sets empty → `uncovered`.
- Escalated runs get budgets derived from their example sets like any
  mutant, and obey the same serial-lane rules.

## 5. Surface

- `--[no-]class-level` CLI flag + `class_level:` yaml key. **Default on**;
  `--no-class-level` restores old behavior.
- `class_level_closure_cap:` yaml key only (no CLI flag), default 10.
- New result status **`skipped`**: excluded from the score denominator
  (like `uncovered`/`accepted`), summarized with reasons at end of run,
  never a failure exit condition. Stryker-json maps it to `Ignored`.
- Acceptance ledger works unchanged (fingerprints are
  description+file+ordinal).

## 6. Docs

- README scope-honesty rewrite: class-level mutation in, with
  Zeitwerk/closure limits; link #31/#32.
- how-it-works: new closure-reload section.
- operators guide: operators now see class-body nodes.
- custom-operators guide: note plugin operators apply to class bodies too.

## 7. Testing

- Unit: finder class-body subjects + Zeitwerk gate; engine class-body walk
  (def/nested-class exclusion); closure computation and ordering with
  fake constants; per-member guards; skip statuses; two-phase scheduling.
- E2E: extend the existing rails_app bench fixture with a concern +
  `validates`; assert the delete-validates mutant is killed, and that an
  untested validation survives with the escalation annotation.
- Self-mutation gate green per task, as always.

## 8. Bundled chore (first commit of the branch)

Gemspec hygiene: `prism ">= 0.30", "< 2"` (prism is on 1.x — plain
`~> 0.30` would be wrong), `rspec-core "~> 3.12"`, drop the duplicate
`source_code_uri`/`homepage_uri` metadata warning.

## Rejected alternatives

- **Macro-registry reset (no reload):** `clear_validators!` + re-execute
  mutated body on the live class. Couples to ActiveModel internals per
  macro family, breaks silently on unknown DSLs, and cannot express
  deletion mutants of already-executed statements.
- **Full app boot per mutant:** most correct semantics, but 10–60s per
  mutant on real apps — destroys the preload architecture.
