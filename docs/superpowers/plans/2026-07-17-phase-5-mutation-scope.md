# Phase 5: Mutation Scope Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen what active_mutator can mutate: bigger CallSwap pack (#5), heredoc bodies (#4), nested-def bodies and `class << self` methods (#3), and a public operator plugin API (#6).

**Architecture:** All four features ride the existing pipeline. #5 and #4 are pure operator changes (CallSwap table, Literal heredoc-aware span). #3 splits in two: nested defs are mutated **under the outer subject** (Engine#walk stops bailing on nested `DefNode`s — a separate subject identity would be silently reverted whenever the outer method re-runs and re-defines the nested def), and `class << self` defs become `:singleton` subjects with a new `sclass` flag that routes Inserter through `singleton_class.class_eval`. #6 exposes the existing self-registering `Operators::Base` registry: a new `operator_paths` config/CLI input required in the parent process before Engine analysis, plus docs and a stability policy.

**Scope note:** Issue #2 (class-level code: macros, constants, DSL blocks) is deliberately NOT in this plan. It needs a different insertion strategy (whole-class reload in the fork) with real design decisions (constant removal, macro re-execution side effects, Rails autoloading) — separate brainstorm + plan.

**Tech Stack:** Ruby ≥ 3.2, Prism, RSpec. Test helper: `mutations_of(source, operator)` from `spec/support/operator_helper.rb` returns mutated source strings.

**Branch:** `phase-5-mutation-scope`

**Gates for every task:** `bundle exec rspec` 0 failures, then `bundle exec exe/active_mutator lib --changed` exit 0 before finishing the task. Subagents NEVER modify `.active_mutator_accepted.json` and NEVER run `--accept-survivors`; a genuinely-equivalent survivor is reported BLOCKED to the controller.

---

### Task 1: CallSwap pack expansion (#5)

**Files:**
- Modify: `lib/active_mutator/operators/call_swap.rb`
- Test: `spec/active_mutator/operators/call_swap_spec.rb`

New swaps, each with a one-directional design check (matching the existing map→each reasoning):

| swap | direction | rationale |
|---|---|---|
| `all?` → `any?` | one-way | `any?` already maps to `none?`; reverse would double-map. Differs on any mixed collection. |
| `take` ↔ `drop` | both | Same arity, complementary partitions; differs for any 0 < n < size. |
| `min_by` ↔ `max_by` | both | Mirrors existing min/max pair. |
| `sort` → `reverse` | one-way | reverse→sort on typically-sorted data would be near-equivalent noise. |
| `detect` → `first` | one-way | `first` ignores the block, returns head; reverse (`first`→`detect`) without a block is invalid/equivalent. |
| `find` → `first` | one-way | Alias of detect. |

Evaluated and rejected (record in a code comment): `sum` (initial-argument arity mismatch and type-change noise), `find_index` (no safe partner: `rindex` is Array-only and block/arg semantics diverge).

- [ ] **Step 1: Write the failing table-driven specs**

Append inside the existing `RSpec.describe ActiveMutator::Operators::CallSwap` block in `spec/active_mutator/operators/call_swap_spec.rb`, following the file's existing `{from => to}.each` style:

```ruby
{
  "xs.all? { |x| x > 1 }" => "xs.any? { |x| x > 1 }",
  "xs.take(2)" => "xs.drop(2)",
  "xs.drop(2)" => "xs.take(2)",
  "xs.min_by(&:size)" => "xs.max_by(&:size)",
  "xs.max_by(&:size)" => "xs.min_by(&:size)",
  "xs.sort" => "xs.reverse",
  "xs.detect { |x| x.odd? }" => "xs.first { |x| x.odd? }",
  "xs.find { |x| x.odd? }" => "xs.first { |x| x.odd? }"
}.each do |from, to|
  it "swaps #{from} to #{to}" do
    expect(mutations_of(from, described_class.new)).to include(to)
  end
end

it "does not swap the reverse of one-directional pairs" do
  expect(mutations_of("xs.any? { |x| x }", described_class.new)).to eq(["xs.none? { |x| x }"])
  expect(mutations_of("xs.reverse", described_class.new)).to eq([])
  expect(mutations_of("xs.first", described_class.new)).to eq(["xs.last"])
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/operators/call_swap_spec.rb`
Expected: new examples FAIL (mutation missing from result).

- [ ] **Step 3: Extend the MAP**

In `lib/active_mutator/operators/call_swap.rb`, replace the `MAP` constant:

```ruby
      # One-directional where the reverse is usually an equivalent mutant
      # (e.g. each→map when return value is unused). Evaluated and rejected:
      # sum (initial-arg arity mismatch), find_index (no safe partner —
      # rindex is Array-only).
      MAP = {
        map: "each",
        select: "reject", reject: "select",
        min: "max", max: "min",
        min_by: "max_by", max_by: "min_by",
        first: "last", last: "first",
        any?: "none?", none?: "any?",
        all?: "any?",              # one-way: any? already pairs with none?
        take: "drop", drop: "take",
        sort: "reverse",           # one-way: reverse→sort near-equivalent on sorted data
        detect: "first",           # one-way: first ignores the block
        find: "first",
        # Rails-aware pack:
        present?: "blank?", blank?: "present?",
        save: "save!", save!: "save"
      }.freeze
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/active_mutator/operators/call_swap_spec.rb`
Expected: PASS, all examples.

- [ ] **Step 5: Full suite + self-mutation gate, then commit**

Run: `bundle exec rspec` (expect 0 failures), then `bundle exec exe/active_mutator lib --changed` (expect exit 0).

```bash
git add lib/active_mutator/operators/call_swap.rb spec/active_mutator/operators/call_swap_spec.rb
git commit -m "feat: broaden CallSwap pack (all?/take/drop/min_by/max_by/sort/detect/find) (#5)"
```

---

### Task 2: Heredoc body mutation (#4)

**Files:**
- Modify: `lib/active_mutator/operators/literal.rb`
- Test: `spec/active_mutator/operators/literal_spec.rb`

Design: for a plain (non-interpolated) heredoc `Prism::StringNode`, the node span covers the opening `<<~X` token — splicing there breaks the source. Instead mutate `node.content_loc` (the body byte range, including trailing newline): nonempty body → replace with `""` (a legal empty heredoc: opening line immediately followed by the terminator). Empty heredoc → skip (nothing meaningful to insert without terminator-indentation games). Interpolated heredocs are `InterpolatedStringNode`s and stay untouched by construction.

- [ ] **Step 1: Write the failing specs**

In `spec/active_mutator/operators/literal_spec.rb`, replace the existing heredoc-skip example (currently asserting heredocs produce no mutations, around lines 38-40) with:

```ruby
it "empties a plain heredoc body instead of touching the opening token" do
  src = "x = <<~SQL\n  select 1\nSQL\n"
  expect(mutations_of(src, described_class.new)).to include("x = <<~SQL\nSQL\n")
end

it "empties a non-squiggly heredoc body" do
  src = "x = <<-TXT\n  hi\n  TXT\n"
  expect(mutations_of(src, described_class.new)).to include("x = <<-TXT\n  TXT\n")
end

it "describes the heredoc mutation" do
  src = "x = <<~SQL\n  select 1\nSQL\n"
  expect(descriptions_of(src)).to include("empty heredoc body")
end

it "skips already-empty heredocs" do
  src = "x = <<~SQL\nSQL\n"
  expect(mutations_of(src, described_class.new)).to eq([])
end

it "skips interpolated heredocs" do
  src = "x = <<~SQL\n  a\#{b}c\nSQL\n"
  expect(mutations_of(src, described_class.new)).to eq([])
end
```

(Note: in the actual spec file write `a#{b}c` unescaped inside the single-source string — use single-quoted Ruby string or escape as needed so the interpolation lands in the parsed source, not in the spec itself. `descriptions_of` is the helper already defined at the top of this spec file.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/operators/literal_spec.rb`
Expected: FAIL (heredocs currently return no edits).

- [ ] **Step 3: Implement heredoc-aware string_edits**

In `lib/active_mutator/operators/literal.rb`, replace `string_edits`:

```ruby
      def string_edits(node)
        opening = node.opening_loc&.slice
        return [] unless opening                # quote-less parts (interpolation)
        return heredoc_edits(node) if opening.start_with?("<<")

        if node.unescaped.empty?
          [edit(loc_range(node.location), %("active_mutator"), %(replace "" with "active_mutator"))]
        else
          [edit(loc_range(node.location), %(""), %(replace string with ""))]
        end
      end

      # The node span covers the `<<~X` opening token; splicing there breaks
      # the source. Mutate the body content range instead: nonempty body →
      # empty heredoc (opening line directly followed by the terminator).
      def heredoc_edits(node)
        return [] if node.unescaped.empty?

        [edit(loc_range(node.content_loc), "", "empty heredoc body")]
      end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/active_mutator/operators/literal_spec.rb`
Expected: PASS. If the `<<-TXT` case fails because `content_loc` includes the terminator indentation, adjust the expected string to whatever valid Ruby the splice produces — verify validity by checking the property/reparse suite still passes (`bundle exec rspec spec/property`).

- [ ] **Step 5: Full suite + gate, commit**

Run: `bundle exec rspec` then `bundle exec exe/active_mutator lib --changed` (exit 0).

```bash
git add lib/active_mutator/operators/literal.rb spec/active_mutator/operators/literal_spec.rb
git commit -m "feat: mutate heredoc bodies via content range (#4)"
```

---

### Task 3: Nested-def bodies mutated under the outer subject (#3, part 1)

**Files:**
- Modify: `lib/active_mutator/engine.rb:47` (the `walk` bail)
- Modify: `lib/active_mutator/subject_finder.rb:61` (comment only)
- Test: `spec/active_mutator/engine_spec.rb`

Design (deviation from issue #3 wording, on purpose): giving nested defs their own subject identity is a trap — every call of the outer method re-executes the nested `def`, silently reverting a directly-inserted mutant mid-run and producing phantom survivors. Instead, Engine#walk descends into nested `DefNode`s so their bodies are mutated **as part of the outer def's source**; Inserter re-evals the outer def, which then defines the mutated nested def whenever it runs. SubjectFinder still emits no subject for nested defs.

- [ ] **Step 1: Write the failing test**

In `spec/active_mutator/engine_spec.rb` (create the describe block if the file lacks one for this; follow the file's existing style for building a Subject — read the file first):

```ruby
it "mutates nested def bodies under the outer subject" do
  source = <<~RUBY
    class Outer
      def build
        def helper
          1 + 1
        end
      end
    end
  RUBY
  subject_ = ActiveMutator::Subject.new(
    name: "Outer#build", file: "outer.rb",
    byte_range: source.index("def build")...source.rindex("end"),
    line_range: 2..6, constant_scope: "Outer", kind: :instance
  )
  analysis = described_class.new.analyze(subject_, source: source)
  descriptions = analysis.mutations.map { |m| m.edit.description }
  expect(descriptions).to include("replace `1` with `0`")
end
```

(Adjust `byte_range` construction to match how existing engine specs build subjects — the begin offset must be the outer `def`'s start offset. If the file already has a helper for this, use it.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/engine_spec.rb`
Expected: FAIL — no mutations from the nested body (walk bails on `DefNode`).

- [ ] **Step 3: Remove the bail**

In `lib/active_mutator/engine.rb`, change `walk`:

```ruby
    def walk(node, &blk)
      return if node.nil?

      # Nested DefNodes are descended: their bodies mutate as part of the
      # OUTER def's re-evaled source. A separate subject identity would be
      # silently reverted every time the outer method runs and re-defines
      # the nested def.
      yield node
      node.compact_child_nodes.each { |child| walk(child, &blk) }
    end
```

Update the stale comment in `lib/active_mutator/subject_finder.rb` `visit_def_node` (last line of the method):

```ruby
      # No `super`: nested defs get no subject of their own — their bodies
      # are mutated via the OUTER def (Engine#walk descends into them).
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/active_mutator/engine_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + gate, commit**

Run: `bundle exec rspec` then `bundle exec exe/active_mutator lib --changed` (exit 0).

```bash
git add lib/active_mutator/engine.rb lib/active_mutator/subject_finder.rb spec/active_mutator/engine_spec.rb
git commit -m "feat: mutate nested def bodies under the outer subject (#3)"
```

---

### Task 4: `class << self` subjects (#3, part 2)

**Files:**
- Modify: `lib/active_mutator/subject.rb`
- Modify: `lib/active_mutator/subject_finder.rb`
- Modify: `lib/active_mutator/inserter.rb`
- Test: `spec/active_mutator/subject_finder_spec.rb`, `spec/active_mutator/inserter_spec.rb`

Design: a def inside `class << self` is a singleton method, but its source slice is `def foo` — `class_eval` on the constant would define an *instance* method. So: SubjectFinder tracks sclass depth (only for `class << self` with a surrounding constant scope; `class << obj` and top-level `class << self` stay skipped), stamps `kind: :singleton, sclass: true`; Inserter routes `sclass` subjects through `.singleton_class.class_eval`. `Subject` gains an `sclass` member defaulting to `false` so every existing construction site keeps working.

- [ ] **Step 1: Write the failing SubjectFinder specs**

In `spec/active_mutator/subject_finder_spec.rb` (follow the file's existing pattern for feeding source — likely a tempfile or a `described_class.call` on a written file; read the file first and reuse its helper):

```ruby
it "finds defs inside class << self as sclass singleton subjects" do
  subjects = subjects_of(<<~RUBY)
    class Foo
      class << self
        def bar
          1
        end
      end
    end
  RUBY
  s = subjects.fetch(0)
  expect(s.name).to eq("Foo.bar")
  expect(s.kind).to eq(:singleton)
  expect(s.sclass).to be true
  expect(s.constant_scope).to eq("Foo")
end

it "still skips class << obj and top-level class << self" do
  expect(subjects_of("class << $x\n  def a; end\nend")).to be_empty
  expect(subjects_of("class << self\n  def a; end\nend")).to be_empty
end

it "does not mark ordinary def self.x subjects as sclass" do
  s = subjects_of("class Foo\n  def self.bar; end\nend").fetch(0)
  expect(s.sclass).to be false
end
```

(`subjects_of` = whatever helper the spec file already uses to run `SubjectFinder.call` on inline source; if none exists, add one writing to a Tempfile.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/subject_finder_spec.rb`
Expected: FAIL (`class << self` bodies unvisited; `Subject` has no `sclass`).

- [ ] **Step 3: Implement Subject + SubjectFinder**

`lib/active_mutator/subject.rb`:

```ruby
module ActiveMutator
  # A mutable unit: one method definition.
  # byte_range/line_range cover the whole `def ... end`.
  # sclass: def lives inside `class << self` — its source slice is `def foo`,
  # so Inserter must target the singleton class, not the constant itself.
  Subject = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind, :sclass) do
    def initialize(name:, file:, byte_range:, line_range:, constant_scope:, kind:, sclass: false)
      super
    end

    def singleton? = kind == :singleton
  end
end
```

`lib/active_mutator/subject_finder.rb` — initialize gains `@sclass_depth = 0`; replace `visit_singleton_class_node` and `visit_def_node`:

```ruby
    # `class << self` inside a constant scope: defs there are singleton
    # methods of the enclosing constant. `class << obj` and a top-level
    # `class << self` (no constant to hang the method on) stay skipped.
    def visit_singleton_class_node(node)
      return unless node.expression.is_a?(Prism::SelfNode) && !@stack.empty?

      @sclass_depth += 1
      begin
        super
      ensure
        @sclass_depth -= 1
      end
    end

    def visit_def_node(node)
      return if @skip_lines.include?(node.location.start_line - 1)

      sclass = @sclass_depth.positive?
      singleton = sclass || node.receiver.is_a?(Prism::SelfNode)
      scope = @stack.empty? ? nil : @stack.join("::")
      loc = node.location
      @subjects << Subject.new(
        name: "#{scope || "Object"}#{singleton ? "." : "#"}#{node.name}",
        file: @file,
        byte_range: loc.start_offset...loc.end_offset,
        line_range: loc.start_line..loc.end_line,
        constant_scope: scope,
        kind: singleton ? :singleton : :instance,
        sclass: sclass
      )
      # No `super`: nested defs get no subject of their own — their bodies
      # are mutated via the OUTER def (Engine#walk descends into them).
    end
```

- [ ] **Step 4: Run to verify SubjectFinder pass**

Run: `bundle exec rspec spec/active_mutator/subject_finder_spec.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing Inserter spec**

In `spec/active_mutator/inserter_spec.rb` (reuse the file's existing pattern for building a Mutation + defining a scratch class):

```ruby
it "redefines an sclass singleton method on the singleton class" do
  klass = Class.new
  stub_const("SclassHost", klass)
  SclassHost.singleton_class.class_eval("def bar; 1; end", __FILE__, __LINE__)
  subject_ = ActiveMutator::Subject.new(
    name: "SclassHost.bar", file: "x.rb", byte_range: 0...1, line_range: 1..1,
    constant_scope: "SclassHost", kind: :singleton, sclass: true
  )
  mutation = ActiveMutator::Mutation.new(
    subject: subject_, edit: nil, original_snippet: "1", line: 1,
    mutated_file_source: "", mutated_def_source: "def bar; 2; end",
    mutated_def_line: 1
  )
  described_class.new.insert(mutation)
  expect(SclassHost.bar).to eq(2)
end
```

(Match `Mutation.new` keywords to `lib/active_mutator/mutation.rb` — read it; pass whatever minimal values it requires.)

- [ ] **Step 6: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/inserter_spec.rb`
Expected: FAIL — `SclassHost.bar` still 1 (mutant landed as an instance method).

- [ ] **Step 7: Implement Inserter routing**

`lib/active_mutator/inserter.rb`:

```ruby
module ActiveMutator
  # Redefines the subject's method with its mutated source. `class_eval` of a
  # `def` handles instance methods; a `def self.x` source string defines the
  # singleton method the same way. Defs from `class << self` bodies (sclass)
  # are plain `def foo` slices, so they eval on the singleton class instead.
  # Top-level subjects eval at main scope.
  class Inserter
    def insert(mutation)
      subject = mutation.subject
      if subject.constant_scope
        target = Object.const_get(subject.constant_scope)
        target = target.singleton_class if subject.sclass
        target.class_eval(mutation.mutated_def_source, subject.file, mutation.mutated_def_line)
      else
        eval(mutation.mutated_def_source, TOPLEVEL_BINDING, # rubocop:disable Security/Eval
             subject.file, mutation.mutated_def_line)
      end
      nil
    end
  end
end
```

- [ ] **Step 8: Run to verify pass, full suite + gate, commit**

Run: `bundle exec rspec spec/active_mutator/inserter_spec.rb`, then `bundle exec rspec`, then `bundle exec exe/active_mutator lib --changed` (exit 0).

```bash
git add lib/active_mutator/subject.rb lib/active_mutator/subject_finder.rb lib/active_mutator/inserter.rb spec/active_mutator/subject_finder_spec.rb spec/active_mutator/inserter_spec.rb
git commit -m "feat: mutate class << self bodies as sclass singleton subjects (#3)"
```

---

### Task 5: Operator plugin API (#6)

**Files:**
- Modify: `lib/active_mutator/config.rb` (add `operator_paths`)
- Modify: `lib/active_mutator/cli.rb` (`--operator FILE`, default `operator_paths: []`)
- Modify: `lib/active_mutator/config_file.rb` (`"operators" => :string_list` mapped to `operator_paths`)
- Modify: `lib/active_mutator/runner.rb` (load operator files in the PARENT before `Engine.new.analyze`)
- Create: `docs/guides/custom-operators.md`
- Test: `spec/active_mutator/cli_spec.rb`, `spec/active_mutator/config_file_spec.rb`, `spec/active_mutator/runner_spec.rb` (or wherever runner planning is specced — read the spec dir first)

Design: the registration mechanism already exists — subclassing `Operators::Base` self-registers via `inherited`. The missing piece is a supported way to load user files at the right time: the parent process, before subjects are analyzed (`runner.rb:17`), so mutations are generated with the custom operator and forks inherit it. `requires` can't serve — it loads inside the fork's setup, after analysis.

- [ ] **Step 1: Write the failing config plumbing specs**

CLI spec (follow existing option-parsing examples in `spec/active_mutator/cli_spec.rb`):

```ruby
it "collects repeatable --operator paths" do
  config = parse(%w[lib --operator ./ops/a.rb --operator ./ops/b.rb])
  expect(config.operator_paths).to eq(["./ops/a.rb", "./ops/b.rb"])
end

it "defaults operator_paths to empty" do
  expect(parse(%w[lib]).operator_paths).to eq([])
end
```

Config-file spec (follow existing key examples in `spec/active_mutator/config_file_spec.rb`):

```ruby
it "reads operators as a string list into operator_paths" do
  write_config("operators:\n  - ops/custom.rb\n")
  expect(load_config.fetch(:operator_paths)).to eq(["ops/custom.rb"])
end
```

(Use each spec file's existing helpers verbatim — `parse`/`write_config`/`load_config` here are stand-ins for whatever those files actually call; read them first.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/cli_spec.rb spec/active_mutator/config_file_spec.rb`
Expected: FAIL (unknown option / unknown key / missing Config member).

- [ ] **Step 3: Implement config plumbing**

`lib/active_mutator/config.rb` — append `:operator_paths` to the `Data.define` list.

`lib/active_mutator/cli.rb` — add `operator_paths: []` to the defaults hash (near `requires: []`, line ~23) and next to the `--require` option (line ~36):

```ruby
        o.on("--operator FILE", "Ruby file defining a custom operator, loaded before analysis (repeatable)") { |v| options[:operator_paths] << v }
```

`lib/active_mutator/config_file.rb` — in `KEYS`, add:

```ruby
      "operators" => :string_list,
```

and map the YAML key `operators` to the config member `operator_paths` wherever the file translates keys to symbols (read the file: if it symbolizes key names directly, add an explicit rename step `operators → operator_paths`).

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/active_mutator/cli_spec.rb spec/active_mutator/config_file_spec.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing runner-load spec**

In the runner spec (read `spec/active_mutator/runner_spec.rb` for its construction pattern; if runner has no unit spec, put this in a new focused spec file):

```ruby
it "loads operator files in the parent before analysis" do
  Dir.mktmpdir do |dir|
    op = File.join(dir, "shout_op.rb")
    File.write(op, <<~RUBY)
      class ShoutOp < ActiveMutator::Operators::Base
        def edits(node) = []
      end
    RUBY
    config = build_config(root: dir, operator_paths: ["shout_op.rb"])
    described_class.new(config).send(:load_operators)
    expect(ActiveMutator::Operators::Base.all.map { |o| o.class.name }).to include("ShoutOp")
  end
end
```

(`build_config` = however runner specs build a Config; ensure the registry pollution is cleaned: `after { ActiveMutator::Operators::Base::REGISTRY.delete(ShoutOp) if defined?(ShoutOp) }`.)

- [ ] **Step 6: Run to verify failure**

Expected: FAIL (`load_operators` undefined).

- [ ] **Step 7: Implement runner load**

In `lib/active_mutator/runner.rb`, at the top of `call` (before the `subjects.map { |s| Engine.new.analyze(s) }` line):

```ruby
      load_operators
```

and add the private method:

```ruby
    # Custom operators must exist in the PARENT before Engine analysis:
    # subclassing Operators::Base self-registers, and forks inherit the
    # loaded class. `requires` can't serve — those load inside the fork's
    # setup, after mutations are already planned.
    def load_operators
      @config.operator_paths.each { |f| require File.expand_path(f, @config.root) }
    end
```

- [ ] **Step 8: Run to verify pass**

Run: the runner spec file. Expected: PASS.

- [ ] **Step 9: Write docs + stability policy**

Create `docs/guides/custom-operators.md`:

```markdown
# Custom Operators

Register your own mutation operators without patching the gem.

## Writing an operator

Subclass `ActiveMutator::Operators::Base`. Subclassing IS registration —
the base class tracks every subclass and the engine instantiates them all.

```ruby
# ops/nil_guard.rb
class NilGuard < ActiveMutator::Operators::Base
  # Called for every Prism AST node inside each mutated method body.
  # Return an array of edits (or [] when the node doesn't apply).
  def edits(node)
    return [] unless node.is_a?(Prism::CallNode) && node.name == :fetch

    [edit(loc_range(node.message_loc), "[]", "replace `.fetch` with `.[]`")]
  end
end
```

Helpers available inside an operator:

- `edit(range, replacement, description)` — build an edit. `range` is an
  exclusive **byte** range into the original file source; `replacement` is
  the literal text spliced in; `description` appears in reports.
- `loc_range(loc)` — convert a Prism location to that byte range.

Every mutated file is re-parsed before use; an edit producing invalid Ruby
is dropped and counted, never run.

## Loading

CLI (repeatable):

    active_mutator lib --operator ops/nil_guard.rb

Or `.active_mutator.yml`:

```yaml
operators:
  - ops/nil_guard.rb
```

Paths resolve against the project root. Files load in the parent process
before analysis, so `--require`d app code is NOT yet loaded — operators
must be self-contained (Prism is available).

## Stability policy

Public and semver-stable from 0.2:

- `ActiveMutator::Operators::Base` subclass-registration, `#edits(node)`,
  `#edit`, `#loc_range`
- `ActiveMutator::Edit` members (`range`, `replacement`, `description`,
  `operator`)

The `node` argument is a Prism AST node: its API follows the `prism` gem,
not this one. Pin `prism` if you need parser-level stability.
```

Add a link line to `README.md`'s docs/guides index (read README, match its list style) and mention the `operators:` key in the config-file section if one exists.

- [ ] **Step 10: Full suite + gate, commit**

Run: `bundle exec rspec` then `bundle exec exe/active_mutator lib --changed` (exit 0).

```bash
git add lib/active_mutator/config.rb lib/active_mutator/cli.rb lib/active_mutator/config_file.rb lib/active_mutator/runner.rb docs/guides/custom-operators.md README.md spec/
git commit -m "feat: operator plugin API — --operator flag, operators: config key, docs (#6)"
```

---

### Task 6: Scope-honesty docs sweep

**Files:**
- Modify: `README.md` (scope/limits section)
- Modify: `docs/guides/how-it-works.md` (operator list, subject discovery, limits)

- [ ] **Step 1: Update limits**

Grep both files for `heredoc`, `class << self`, `nested def`:

Run: `grep -n -i "heredoc\|class << self\|nested def" README.md docs/guides/how-it-works.md`

For every hit describing a v1 limit now lifted, rewrite to the new behavior:
- heredocs: bodies ARE mutated (emptied); interpolated heredocs still skipped.
- `class << self`: mutated (singleton subjects); `class << obj` and top-level `class << self` still skipped.
- nested defs: bodies mutated via the outer subject; no separate subject identity (state the revert-race rationale in one sentence).

Remaining honest limits to keep/state: class-level code (macros, constants, DSL blocks — issue #2), defs inside blocks.

Also: add the new CallSwap entries wherever the operator table in how-it-works enumerates swaps, and list `--operator` / `operators:` in any flag/config reference tables.

- [ ] **Step 2: Verify + commit**

Run: `bundle exec rspec` (docs-only change, still run), `grep` again to confirm no stale claims.

```bash
git add README.md docs/guides/how-it-works.md
git commit -m "docs: update scope honesty for phase 5 (heredocs, sclass, nested defs, plugin API)"
```

---

## Self-review notes

- Spec coverage: #5 → Task 1, #4 → Task 2, #3 → Tasks 3+4, #6 → Task 5, docs → Task 6. #2 explicitly out of scope (header note).
- Type consistency: `Subject.sclass` (Task 4) is the only schema change; Task 4 gives it a default so Tasks 1-3 and all existing call sites are unaffected. `operator_paths` naming consistent across config/cli/config_file/runner in Task 5.
- Known verify-at-implementation points (flagged inline, not placeholders): exact `content_loc` extent for `<<-` heredocs (Task 2 Step 4), each spec file's existing helper names (Tasks 4-5), config_file key-renaming mechanism (Task 5 Step 3).
