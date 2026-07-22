# Class-Level Mutation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mutate class-level code (Rails macros, constants, DSL lambdas) via class-body subjects and whole-file closure reload in the fork (issue #2), plus a gemspec dependency-pinning chore.

**Architecture:** `SubjectFinder` emits a second subject kind (`:class_body`) for Zeitwerk-shaped files. `Engine` walks class-body statements (skipping def/class/module/sclass/block subtrees) with the existing operator set; the mutant is the whole file with the edit spliced. In the fork, a new `ClosureReload` unit removes the target constant plus everything attached to it (includers, extenders, subclasses — found via one `ObjectSpace` scan) and re-evals their files, mutated source for the target, pristine for the rest. Kill runs are two-phase: fast set first, constant-reference escalation before a survivor is declared. A new `skipped` result status carries guard failures.

**Tech Stack:** Ruby 3.2+, Prism, RSpec, fork-per-mutant pipeline (all existing).

**Spec:** `docs/superpowers/specs/2026-07-22-class-level-mutation-design.md`

**Per-task gates (project convention):** after each task, `bundle exec rspec` green AND self-mutation gate `bundle exec exe/active_mutator lib --changed` exit 0 (redirect to a file and check `$?` directly — never pipe to tail). Genuine equivalent survivors: report BLOCKED; never run `--accept-survivors`, never touch `.active_mutator_accepted.json`.

---

## File map

| File | Change |
|---|---|
| `active_mutator.gemspec` | Task 1: dependency pins, metadata dedupe |
| `lib/active_mutator/subject.rb` | Task 2: `class_body?` predicate, comment |
| `lib/active_mutator/subject_finder.rb` | Task 2: emit class-body subjects + Zeitwerk gate |
| `lib/active_mutator/engine.rb` | Task 3: class-body analysis path |
| `lib/active_mutator/config.rb`, `cli.rb`, `config_file.rb` | Task 4: `class_level`, `class_level_closure_cap` |
| `lib/active_mutator/runner.rb` | Task 4 (filter), Task 6 (cap wiring), Task 7 (phase-1 plan), Task 8 (escalation) |
| `lib/active_mutator/closure_reload.rb` (new) | Task 5 |
| `lib/active_mutator.rb` | Task 5: require line |
| `lib/active_mutator/worker.rb` | Task 6: class-body insertion branch, skipped status |
| `lib/active_mutator/reporter/terminal.rb` | Task 9: skipped char/count/reasons, escalation annotation |
| `lib/active_mutator/reporter/stryker_json.rb` | Task 9: `skipped` → `Ignored` |
| `README.md`, `docs/guides/how-it-works.md`, `docs/guides/operators.md`, `docs/guides/custom-operators.md` | Task 11 |
| `spec/fixtures/class_level_project/` (new) | Task 10 e2e fixture |

---

### Task 1: Gemspec hygiene chore

**Files:**
- Modify: `active_mutator.gemspec`

- [ ] **Step 1: Edit the gemspec**

Replace the dependency lines:

```ruby
  spec.add_dependency "prism", ">= 0.30"
  spec.add_dependency "rspec-core", ">= 3.12" # worker + baseline_hooks require it at runtime
```

with:

```ruby
  # prism is on 1.x; "~> 0.30" would exclude it. Upper-bound at the next major.
  spec.add_dependency "prism", ">= 0.30", "< 2"
  spec.add_dependency "rspec-core", "~> 3.12" # worker + baseline_hooks require it at runtime
```

In the `spec.metadata` hash, delete the `"homepage_uri"` line (it duplicates `spec.homepage`; RubyGems warns and shows only one). Keep `source_code_uri`.

- [ ] **Step 2: Verify the gem builds clean**

Run: `gem build active_mutator.gemspec 2>&1 | grep -c WARNING; rm -f active_mutator-*.gem`
Expected: `0` (no warnings). If nonzero, read the warnings and fix.

- [ ] **Step 3: Verify suite still green**

Run: `bundle exec rspec > /tmp/t1.out 2>&1; echo $?` then check the tail of `/tmp/t1.out`.
Expected: exit 0, `0 failures`.

- [ ] **Step 4: Commit**

```bash
git add active_mutator.gemspec
git commit -m "chore: pin prism/rspec-core dependency bounds, drop duplicate homepage_uri"
```

---

### Task 2: `:class_body` subjects in SubjectFinder

**Files:**
- Modify: `lib/active_mutator/subject.rb`
- Modify: `lib/active_mutator/subject_finder.rb`
- Test: `spec/active_mutator/subject_finder_spec.rb`

**Context:** `Subject` is a `Data` type; `SubjectFinder` is a `Prism::Visitor` maintaining `@stack` (constant scope) and `@sclass_depth`. Class-body subjects are emitted per class/module node that has at least one non-def/non-class/non-module body statement, only when the file is Zeitwerk-shaped (exactly one top-level class/module node). The subject's byte range is the whole class node span — `Engine` uses `byte_range.begin` to re-find the node.

- [ ] **Step 1: Write failing tests**

Append to `spec/active_mutator/subject_finder_spec.rb` (inside the top-level describe; the file already defines `subjects_of(source)` writing a tmp file and calling `described_class.call`):

```ruby
  describe "class-body subjects" do
    it "emits a class-body subject for a class with macro statements" do
      subjects = subjects_of(<<~RUBY)
        class User
          validates :email, presence: true

          def name = "x"
        end
      RUBY
      body = subjects.find { |s| s.kind == :class_body }
      expect(body.name).to eq("User (class body)")
      expect(body.constant_scope).to eq("User")
      expect(body.class_body?).to be(true)
      expect(body.line_range).to eq(1..5)
      expect(subjects.map(&:name)).to include("User#name")
    end

    it "emits no class-body subject when the body is only defs" do
      subjects = subjects_of(<<~RUBY)
        class User
          def name = "x"
        end
      RUBY
      expect(subjects.map(&:kind)).to eq([:instance])
    end

    it "emits class-body subjects for nested classes but not namespace wrappers" do
      subjects = subjects_of(<<~RUBY)
        module Billing
          class Calculator
            RATE = 2
          end
        end
      RUBY
      bodies = subjects.select { |s| s.kind == :class_body }
      expect(bodies.map(&:name)).to eq(["Billing::Calculator (class body)"])
    end

    it "gates on Zeitwerk shape: no class-body subjects when a file defines two top-level constants" do
      subjects = subjects_of(<<~RUBY)
        class A
          X = 1
        end
        class B
          Y = 2
        end
      RUBY
      expect(subjects.select { |s| s.kind == :class_body }).to be_empty
    end

    it "skips a class-body subject with active_mutator:skip above the class line" do
      subjects = subjects_of(<<~RUBY)
        # active_mutator:skip
        class User
          X = 1
        end
      RUBY
      expect(subjects.select { |s| s.kind == :class_body }).to be_empty
    end

    it "emits module class-body subjects" do
      subjects = subjects_of(<<~RUBY)
        module Util
          TIMEOUT = 5
          def helper = 1
        end
      RUBY
      body = subjects.find { |s| s.kind == :class_body }
      expect(body.name).to eq("Util (class body)")
    end

    it "emits no class-body subject inside class << self" do
      subjects = subjects_of(<<~RUBY)
        class Foo
          class << self
            def bar = 1
          end
        end
      RUBY
      expect(subjects.select { |s| s.kind == :class_body }).to be_empty
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/subject_finder_spec.rb`
Expected: FAIL (no `:class_body` subjects exist; `class_body?` NoMethodError).

- [ ] **Step 3: Implement**

`lib/active_mutator/subject.rb` — replace the comment block and add the predicate:

```ruby
module ActiveMutator
  # A mutable unit. kind :instance/:singleton = one method definition
  # (byte_range/line_range cover the whole `def ... end`). kind :class_body =
  # the class-level code of one class/module (byte_range covers the whole
  # class/module node; Engine only mutates non-def body statements).
  # sclass: def lives inside `class << self` — its source slice is `def foo`,
  # so Inserter must target the singleton class, not the constant itself.
  Subject = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind, :sclass) do
    def initialize(name:, file:, byte_range:, line_range:, constant_scope:, kind:, sclass: false)
      super
    end

    def singleton? = kind == :singleton

    def class_body? = kind == :class_body
  end
end
```

`lib/active_mutator/subject_finder.rb` — changes:

In `self.call`, compute the Zeitwerk gate and pass it in (replace the two `finder` lines):

```ruby
      finder = new(file, skip_lines: skip_lines,
                   class_level: zeitwerk_shaped?(result.value))
      finder.visit(result.value)
      finder.subjects
    end

    # Class-body subjects only for Zeitwerk-shaped files: exactly one
    # top-level class/module node. Multi-constant files and core-class
    # reopens have no safe remove_const + re-eval story (issue #32).
    def self.zeitwerk_shaped?(program)
      program.statements.body.count do |s|
        s.is_a?(Prism::ClassNode) || s.is_a?(Prism::ModuleNode)
      end == 1
    end
```

In `initialize`, accept and store the flag (add parameter `class_level: true` and `@class_level = class_level`).

In `visit_class_node` and `visit_module_node`, emit the class-body subject inside the scope (both methods change the same way):

```ruby
    def visit_class_node(node)
      return if @sclass_depth.positive?

      with_scope(node.constant_path.slice) do
        add_class_body_subject(node)
        super
      end
    end

    def visit_module_node(node)
      return if @sclass_depth.positive?

      with_scope(node.constant_path.slice) do
        add_class_body_subject(node)
        super
      end
    end
```

Add the private method (note: it runs inside `with_scope`, so `@stack` already includes this node's name):

```ruby
    # One subject for the class-level code of this class/module. Only if the
    # body has at least one statement the class-body walk can mutate: defs
    # and nested class/modules are owned by other subjects.
    def add_class_body_subject(node)
      return unless @class_level
      return if @skip_lines.include?(node.location.start_line - 1)

      body = node.body
      return unless body.is_a?(Prism::StatementsNode)
      return if body.body.all? { |s| owned_by_other_subject?(s) }

      scope = @stack.join("::")
      loc = node.location
      @subjects << Subject.new(
        name: "#{scope} (class body)",
        file: @file,
        byte_range: loc.start_offset...loc.end_offset,
        line_range: loc.start_line..loc.end_line,
        constant_scope: scope,
        kind: :class_body,
        sclass: false
      )
    end

    def owned_by_other_subject?(node)
      node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) ||
        node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)
    end
```

Note the wrapper-module case falls out naturally: `module Billing` containing only `class Calculator` has all body statements owned → no subject.

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/subject_finder_spec.rb`
Expected: PASS, including all pre-existing examples.

- [ ] **Step 5: Full suite + gate**

Run: `bundle exec rspec > /tmp/t2.out 2>&1; echo $?` — expect 0.
Run: `bundle exec exe/active_mutator lib --changed > /tmp/t2gate.out 2>&1; echo $?` — expect 0. If phantom survivors from a stale baseline, retry once with `--force-baseline`, then re-run plain.

NOTE: at this point downstream code cannot handle class-body subjects — `Engine#analyze` would raise "subject not found" (find_def returns nil for a class node), breaking the gate. **This task therefore also adds a temporary guard in `lib/active_mutator/runner.rb`** `discover_subjects` (repointed in Task 3, removed in Task 6): after the `subjects = paths...` assignment, add:

```ruby
      subjects = subjects.reject(&:class_body?) # TODO(Task 3): Engine can't analyze these yet
```

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/subject.rb lib/active_mutator/subject_finder.rb lib/active_mutator/runner.rb spec/active_mutator/subject_finder_spec.rb
git commit -m "feat: discover class-body subjects behind Zeitwerk-shape gate (#2)"
```

---

### Task 3: Engine class-body analysis

**Files:**
- Modify: `lib/active_mutator/engine.rb`
- Modify: `lib/active_mutator/runner.rb` (remove Task 2's temporary reject; add config gate — see Step 3)
- Test: `spec/active_mutator/engine_spec.rb`

**Context:** `Engine#analyze(subject, source:)` currently finds a DefNode at `subject.byte_range.begin` and walks its body. For class-body subjects it must find the Class/Module node, walk only body statements not owned by other subjects (skip DefNode/ClassNode/ModuleNode/SingletonClassNode subtrees AND BlockNode subtrees — association-extension blocks stay out, issue #31; lambdas (`LambdaNode`) ARE descended: scope bodies). The class-body `StatementsNode` itself IS yielded so `StatementDeletion` applies — but deletion edits whose range exactly covers an owned statement must be discarded (deleting a whole `def` is a method-existence mutant, out of scope). Mutation fields: `mutated_file_source` as usual; `mutated_def_source` = the full mutated file and `mutated_def_line` = 1 (Worker routes class-body mutants through ClosureReload, which uses `mutated_file_source`; the def fields are never class_eval'd).

- [ ] **Step 1: Write failing tests**

Append to `spec/active_mutator/engine_spec.rb` (match the file's existing helper style — it builds subjects via `SubjectFinder` on tmp files; reuse whatever helper exists, or build inline as below):

```ruby
  describe "class-body analysis" do
    def class_body_analysis(source)
      Dir.mktmpdir do |dir|
        file = File.join(dir, "user.rb")
        File.write(file, source)
        subject = ActiveMutator::SubjectFinder.call(file).find(&:class_body?)
        [ActiveMutator::Engine.new.analyze(subject, source: source), subject]
      end
    end

    it "mutates macro arguments and statements" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          validates :email, presence: true
          validates :name, length: { minimum: 2 }

          def name = "x"
        end
      RUBY
      descriptions = analysis.mutations.map(&:description)
      expect(descriptions).to include("replace `true` with `false`")
      expect(descriptions).to include("delete `validates :email, presence: true`")
      expect(descriptions).to include("replace `2` with `0`")
    end

    it "does not delete def statements from the class body" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 1
          Y = 2

          def name = "hello"
        end
      RUBY
      expect(analysis.mutations.map(&:description)).not_to include(a_string_matching(/delete `def name/))
    end

    it "does not mutate inside def bodies (owned by method subjects)" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 1
          Y = 2

          def flag = true
        end
      RUBY
      trues = analysis.mutations.select { |m| m.description == "replace `true` with `false`" }
      expect(trues).to be_empty
    end

    it "mutates scope lambda bodies" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          scope :adults, -> { where("age >= 18") }
          X = 1
        end
      RUBY
      expect(analysis.mutations.map(&:description)).to include('replace string with ""')
    end

    it "does not mutate inside macro blocks (association extensions)" do
      analysis, = class_body_analysis(<<~RUBY)
        class User
          X = 1
          has_many :pets do
            def flagged = true
          end
        end
      RUBY
      trues = analysis.mutations.select { |m| m.description == "replace `true` with `false`" }
      expect(trues).to be_empty
    end

    it "produces whole-file mutants that still parse and keep the class node anchored" do
      analysis, subject = class_body_analysis(<<~RUBY)
        class User
          X = 5
          def name = "x"
        end
      RUBY
      m = analysis.mutations.find { |mu| mu.description == "replace `5` with `0`" }
      expect(m.mutated_file_source).to include("X = 0")
      expect(m.mutated_file_source).to include('def name = "x"')
      expect(Prism.parse(m.mutated_file_source)).to be_success
      expect(m.subject).to eq(subject)
    end
  end
```

(Add `require "tmpdir"` at the top of the spec file if not present.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/engine_spec.rb`
Expected: FAIL — `Engine` raises `subject not found` (find_def can't match a class node).

- [ ] **Step 3: Implement**

`lib/active_mutator/engine.rb` — replace `analyze` with a branching version and add the class-body path:

```ruby
    def analyze(subject, source: File.read(subject.file))
      result = Prism.parse(source)
      raise Error, "#{subject.file} no longer parses" unless result.success?

      return analyze_class_body(subject, source, result) if subject.class_body?

      def_node = find_def(result.value, subject.byte_range.begin)
      raise Error, "subject not found: #{subject.name}" unless def_node

      invalid = 0
      mutations = collect_edits(def_node).filter_map do |edit|
        mutation, valid = build_mutation(subject, source, edit)
        invalid += 1 unless valid
        mutation
      end
      Analysis.new(mutations: mutations, invalid_count: invalid)
    end
```

Add these private methods:

```ruby
    def analyze_class_body(subject, source, result)
      class_node = find_class(result.value, subject.byte_range.begin)
      raise Error, "subject not found: #{subject.name}" unless class_node

      invalid = 0
      mutations = collect_class_body_edits(class_node).filter_map do |edit|
        mutation, valid = build_class_body_mutation(subject, source, edit)
        invalid += 1 unless valid
        mutation
      end
      Analysis.new(mutations: mutations, invalid_count: invalid)
    end

    def find_class(node, start_offset)
      if (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)) &&
         node.location.start_offset == start_offset
        return node
      end

      node.compact_child_nodes.each do |child|
        found = find_class(child, start_offset)
        return found if found
      end
      nil
    end

    # Class-level code only: defs, nested class/modules and `class << self`
    # bodies are owned by other subjects; macro blocks (association
    # extensions) are out of scope (issue #31). Lambdas (scope bodies, if:
    # procs) ARE descended. Edits that would delete a whole owned statement
    # (StatementDeletion sees the body StatementsNode) are discarded.
    def collect_class_body_edits(class_node)
      owned = class_node.body.body
                        .select { |s| owned_statement?(s) }
                        .map { |s| s.location.start_offset...s.location.end_offset }
      edits = []
      class_walk(class_node.body) do |node|
        @operators.each do |op|
          edits.concat(op.edits(node))
        rescue StandardError => e
          raise Error, "operator #{op.class.name} failed on #{node.class.name}: #{e.message}"
        end
      end
      edits.reject { |e| owned.include?(e.range) }
    end

    def owned_statement?(node)
      node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) ||
        node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)
    end

    def class_walk(node, &blk)
      return if node.nil? || owned_statement?(node) || node.is_a?(Prism::BlockNode)

      yield node
      node.compact_child_nodes.each { |child| class_walk(child, &blk) }
    end

    # The mutant is the whole file. The def-shaped fields are filled with the
    # file source so the Mutation shape stays uniform; Worker routes
    # class-body mutants through ClosureReload (whole-file re-eval), never
    # through Inserter's class_eval.
    def build_class_body_mutation(subject, source, edit)
      original = source.byteslice(edit.range)
      return [nil, true] if edit.replacement == original

      mutated = Splicer.apply(source, [edit])
      parsed = Prism.parse(mutated)
      return [nil, false] unless parsed.success?
      return [nil, false] unless find_class(parsed.value, subject.byte_range.begin)

      [Mutation.new(
        subject: subject,
        edit: edit,
        original_snippet: original,
        line: source.byteslice(0, edit.range.begin).count("\n") + 1,
        mutated_file_source: mutated,
        mutated_def_source: mutated,
        mutated_def_line: 1
      ), true]
    end
```

`lib/active_mutator/runner.rb` — remove the Task 2 temporary line:

```ruby
      subjects = subjects.reject(&:class_body?) # TODO(Task 3): Engine can't analyze these yet
```

and do NOT replace it yet (Task 4 adds the config-driven filter). The pipeline downstream now handles class-body mutants poorly (Worker would class_eval a whole file — wrong receiver semantics) — that is Task 6. To keep the tree green between tasks, replace the removed line with:

```ruby
      subjects = subjects.reject(&:class_body?) # TODO(Task 6): Worker can't insert these yet
```

(Same behavior, updated pointer. The engine specs drive the new code paths directly.)

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/engine_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + gate**

`bundle exec rspec > /tmp/t3.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t3gate.out 2>&1; echo $?` — expect 0.

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/engine.rb lib/active_mutator/runner.rb spec/active_mutator/engine_spec.rb
git commit -m "feat: Engine analyzes class-body subjects with the full operator set (#2)"
```

---

### Task 4: Config surface — `class_level`, `class_level_closure_cap`

**Files:**
- Modify: `lib/active_mutator/config.rb`, `lib/active_mutator/cli.rb`, `lib/active_mutator/config_file.rb`
- Test: `spec/active_mutator/cli_spec.rb`, `spec/active_mutator/config_file_spec.rb`

- [ ] **Step 1: Write failing tests**

Append to `spec/active_mutator/cli_spec.rb` (match existing parse-spec style — the file tests `ActiveMutator::CLI.parse`):

```ruby
  it "defaults class_level on with cap 10" do
    config = described_class.parse([])
    expect(config.class_level).to be(true)
    expect(config.class_level_closure_cap).to eq(10)
  end

  it "turns class-level mutation off with --no-class-level" do
    expect(described_class.parse(["--no-class-level"]).class_level).to be(false)
  end
```

Append to `spec/active_mutator/config_file_spec.rb` (match existing style — it writes `.active_mutator.yml` into a tmp root and calls `ConfigFile.load`):

```ruby
  it "accepts class_level and class_level_closure_cap" do
    write_config("class_level: false\nclass_level_closure_cap: 25\n")
    expect(described_class.load(root)).to eq(class_level: false, class_level_closure_cap: 25)
  end

  it "rejects a non-boolean class_level" do
    write_config("class_level: 1\n")
    expect { described_class.load(root) }.to raise_error(ActiveMutator::Error, /class_level must be true or false/)
  end
```

(Adapt the helper names `write_config`/`root` to whatever the existing spec file actually uses — read it first.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/cli_spec.rb spec/active_mutator/config_file_spec.rb`
Expected: FAIL (unknown Config members / unknown config key).

- [ ] **Step 3: Implement**

`lib/active_mutator/config.rb`: add `:class_level, :class_level_closure_cap` to the `Data.define` list.

`lib/active_mutator/cli.rb`: in the `options` seed hash add `class_level: true, class_level_closure_cap: 10`; in the OptionParser block add (near `--operator`):

```ruby
        o.on("--[no-]class-level", "Mutate class-level code: macros, constants, DSL lambdas (default: on)") { |v| options[:class_level] = v }
```

(No CLI flag for the cap — config file only, per spec.)

`lib/active_mutator/config_file.rb`: add to `KEYS`:

```ruby
      "class_level" => :boolean,
      "class_level_closure_cap" => :integer,
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/cli_spec.rb spec/active_mutator/config_file_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + gate, commit**

`bundle exec rspec > /tmp/t4.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t4gate.out 2>&1; echo $?` — expect 0.

```bash
git add lib/active_mutator/config.rb lib/active_mutator/cli.rb lib/active_mutator/config_file.rb spec/active_mutator/cli_spec.rb spec/active_mutator/config_file_spec.rb
git commit -m "feat: --[no-]class-level flag and class_level config keys (#2)"
```

---

### Task 5: ClosureReload — fork-side whole-file reload

**Files:**
- Create: `lib/active_mutator/closure_reload.rb`
- Modify: `lib/active_mutator.rb` (add `require_relative "active_mutator/closure_reload"` after the `inserter` line)
- Test: `spec/active_mutator/closure_reload_spec.rb`

**Context:** Runs inside the fork. Given a class-body subject and the mutated whole-file source: resolve the constant, verify it was defined in the subject's file (reopen guard), compute the reload closure via one ObjectSpace scan (includers, subclasses, extenders — all show up via `ancestors`; extend-sites appear as singleton classes, mapped back through `attached_object`), enforce the cap, verify each member is reloadable (named, has a real source file, that file defines exactly one top-level constant), then `remove_const` all members and re-eval files in closure order (target first, attachers after; mutated source for the target, pristine `File.read` for the rest). Every guard failure raises `ClosureReload::Skip` with a reason — the Worker turns that into a `skipped` result.

The cap is a module-level setting (`ClosureReload.cap`) assigned by Runner before scheduling; forks inherit it. Default 10.

**Testing approach:** real constants defined in tmp-file sources and loaded via `eval(src, TOPLEVEL_BINDING, file, 1)` in the spec process, namespaced under a per-example module name to avoid cross-example pollution — and explicitly cleaned in an `after` hook. ObjectSpace scans see the whole spec process; the closure computation starts from OUR target, so foreign constants don't leak in unless they genuinely attach to it.

- [ ] **Step 1: Write failing tests**

Create `spec/active_mutator/closure_reload_spec.rb`:

```ruby
require "tmpdir"

RSpec.describe ActiveMutator::ClosureReload do
  # Each example gets disposable real constants: sources written to tmp
  # files and eval'd with correct __FILE__ attribution, so
  # const_source_location points at the tmp file (the reopen guard checks it).
  let(:dir) { Dir.mktmpdir }
  let(:defined_names) { [] }

  after do
    defined_names.reverse_each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
    FileUtils.remove_entry(dir)
  end

  def load_source(basename, source, top_const:)
    file = File.join(dir, basename)
    File.write(file, source)
    eval(source, TOPLEVEL_BINDING, file, 1) # rubocop:disable Security/Eval
    defined_names << top_const
    file
  end

  def subject_for(file, scope)
    ActiveMutator::SubjectFinder.call(file).find(&:class_body?) ||
      raise("no class-body subject in #{file} (#{scope})")
  end

  it "applies the mutated source to a standalone class" do
    file = load_source("cr_alpha.rb", <<~RUBY, top_const: :CrAlpha)
      class CrAlpha
        RATE = 5
        def rate = RATE
      end
    RUBY
    mutated = File.read(file).sub("RATE = 5", "RATE = 9")
    described_class.new(subject_for(file, "CrAlpha"), mutated).call
    expect(CrAlpha::RATE).to eq(9)
    expect(CrAlpha.new.rate).to eq(9)
  end

  it "reloads includers so module mutations reach them" do
    mod_file = load_source("cr_mixin.rb", <<~RUBY, top_const: :CrMixin)
      module CrMixin
        LIMIT = 5
        def limit = LIMIT
      end
    RUBY
    load_source("cr_host.rb", <<~RUBY, top_const: :CrHost)
      class CrHost
        include CrMixin
      end
    RUBY
    mutated = File.read(mod_file).sub("LIMIT = 5", "LIMIT = 6")
    described_class.new(subject_for(mod_file, "CrMixin"), mutated).call
    expect(CrHost.new.limit).to eq(6)
    expect(CrHost.include?(CrMixin)).to be(true)
  end

  it "reloads subclasses so they point at the fresh superclass" do
    parent_file = load_source("cr_parent.rb", <<~RUBY, top_const: :CrParent)
      class CrParent
        FEE = 1
        def fee = FEE
      end
    RUBY
    load_source("cr_child.rb", <<~RUBY, top_const: :CrChild)
      class CrChild < CrParent
      end
    RUBY
    mutated = File.read(parent_file).sub("FEE = 1", "FEE = 2")
    described_class.new(subject_for(parent_file, "CrParent"), mutated).call
    expect(CrChild.new.fee).to eq(2)
    expect(CrChild.superclass).to eq(CrParent)
  end

  it "reloads extenders (extend sites appear as singleton-class attachers)" do
    mod_file = load_source("cr_ext.rb", <<~RUBY, top_const: :CrExt)
      module CrExt
        def tag = "v1"
      end
    RUBY
    load_source("cr_user_of_ext.rb", <<~RUBY, top_const: :CrUserOfExt)
      class CrUserOfExt
        extend CrExt
      end
    RUBY
    mutated = File.read(mod_file).sub('"v1"', '"v2"')
    described_class.new(subject_for(mod_file, "CrExt"), mutated).call
    expect(CrUserOfExt.tag).to eq("v2")
  end

  it "skips when the closure exceeds the cap" do
    mod_file = load_source("cr_wide.rb", <<~RUBY, top_const: :CrWide)
      module CrWide
        LIMIT = 5
      end
    RUBY
    3.times do |i|
      load_source("cr_wide_host#{i}.rb", <<~RUBY, top_const: :"CrWideHost#{i}")
        class CrWideHost#{i}
          include CrWide
        end
      RUBY
    end
    reload = described_class.new(subject_for(mod_file, "CrWide"), File.read(mod_file))
    expect { reload.call(cap: 2) }
      .to raise_error(described_class::Skip, /closure .*exceeds cap/)
  end

  it "skips when the constant was defined in a different file (reopen guard)" do
    load_source("cr_original.rb", <<~RUBY, top_const: :CrReopened)
      class CrReopened
        X = 1
      end
    RUBY
    reopen_file = File.join(dir, "cr_reopen.rb")
    File.write(reopen_file, <<~RUBY)
      class CrReopened
        Y = 2
      end
    RUBY
    subject = subject_for(reopen_file, "CrReopened")
    expect { described_class.new(subject, File.read(reopen_file)).call }
      .to raise_error(described_class::Skip, /defined at .*cr_original\.rb/)
  end

  it "skips when the constant is not loaded" do
    file = File.join(dir, "cr_never_loaded.rb")
    File.write(file, "class CrNeverLoaded\n  X = 1\nend\n")
    subject = subject_for(file, "CrNeverLoaded")
    expect { described_class.new(subject, File.read(file)).call }
      .to raise_error(described_class::Skip, /not loaded/)
  end

  it "skips when an attacher is anonymous" do
    mod_file = load_source("cr_anon_target.rb", <<~RUBY, top_const: :CrAnonTarget)
      module CrAnonTarget
        LIMIT = 5
      end
    RUBY
    anon = Class.new { include CrAnonTarget }
    subject = subject_for(mod_file, "CrAnonTarget")
    expect { described_class.new(subject, File.read(mod_file)).call }
      .to raise_error(described_class::Skip, /anonymous/)
    anon # keep the reference alive past the call
  end

  it "skips when an attacher's file defines multiple constants" do
    mod_file = load_source("cr_multi_target.rb", <<~RUBY, top_const: :CrMultiTarget)
      module CrMultiTarget
        LIMIT = 5
      end
    RUBY
    load_source("cr_multi_host.rb", <<~RUBY, top_const: :CrMultiHostA)
      class CrMultiHostA
        include CrMultiTarget
      end
      class CrMultiHostB
      end
    RUBY
    defined_names << :CrMultiHostB
    subject = subject_for(mod_file, "CrMultiTarget")
    expect { described_class.new(subject, File.read(mod_file)).call }
      .to raise_error(described_class::Skip, /defines .*constants|multiple top-level/)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/closure_reload_spec.rb`
Expected: FAIL — `ActiveMutator::ClosureReload` undefined.

- [ ] **Step 3: Implement**

Create `lib/active_mutator/closure_reload.rb`:

```ruby
module ActiveMutator
  # Fork-side insertion for class-body mutants. A def mutant can be
  # class_eval'd over the live constant; class-level code cannot (re-running
  # `validates` ADDS a validator, it doesn't replace one). So: remove the
  # constant and re-eval the whole mutated file. Anything already attached to
  # the OLD object — classes that include the module, subclasses, extend
  # sites — would go stale, so they are removed and re-evaled too (pristine
  # sources), dependency-first. The fork dies after the run; nothing is
  # restored.
  #
  # Every guard failure raises Skip; the Worker reports the mutant as
  # `skipped` with the reason. Skipping is honest: a mutant we cannot insert
  # faithfully must not be counted as survived OR killed.
  class ClosureReload
    Skip = Class.new(StandardError)

    DEFAULT_CAP = 10

    class << self
      # Assigned by Runner from config before scheduling; forks inherit it.
      attr_writer :cap

      def cap = @cap || DEFAULT_CAP
    end

    def initialize(subject, mutated_source)
      @subject = subject
      @mutated_source = mutated_source
    end

    def call(cap: self.class.cap)
      target = resolve_target
      closure = compute_closure(target)
      if closure.size > cap
        raise Skip, "reload closure (#{closure.size} constants) exceeds cap (#{cap})"
      end

      sources = closure.map { |mod| [mod.name, source_for(mod)] }
      sources.each { |name, _| remove_constant(name) }
      sources.each do |_, (file, src)|
        eval(src, TOPLEVEL_BINDING, file, 1) # rubocop:disable Security/Eval
      end
      nil
    end

    private

    def resolve_target
      scope = @subject.constant_scope
      target = begin
        Object.const_get(scope)
      rescue NameError
        raise Skip, "constant #{scope} not loaded"
      end
      file, = Object.const_source_location(scope)
      unless file && File.identical?(file, @subject.file)
        raise Skip, "#{scope} defined at #{file || "?"}, not #{@subject.file} (reopened constant)"
      end
      target
    end

    # BFS from the target: attachers of attachers join too. Order matters —
    # the re-eval loop runs in closure order, so a module is fresh before the
    # file that `include`s it re-runs, and a superclass before its subclass.
    def compute_closure(target)
      closure = [target]
      queue = [target]
      until queue.empty?
        attachers(queue.shift, closure).each do |mod|
          closure << mod
          queue << mod
        end
      end
      closure
    end

    # Everything stale after removing `mod`: includers and subclasses carry
    # it in `ancestors`; extend-sites carry it in their singleton class's
    # ancestors, so singleton classes map back through attached_object.
    def attachers(mod, known)
      ObjectSpace.each_object(Module).filter_map do |m|
        next if m.equal?(mod)
        next unless m.ancestors.include?(mod)

        if m.singleton_class?
          m = m.attached_object
          unless m.is_a?(Module)
            raise Skip, "an object instance is extended with #{mod.name || mod.inspect}; not reloadable"
          end
        end
        next if known.include?(m) || m.equal?(mod)

        m
      end.uniq
    end

    def source_for(mod)
      name = mod.name
      raise Skip, "anonymous #{mod.is_a?(Class) ? "class" : "module"} in reload closure" unless name

      return [@subject.file, @mutated_source] if name == @subject.constant_scope

      file, = Object.const_source_location(name)
      raise Skip, "#{name}: no source file (native or dynamically defined)" unless file && File.exist?(file)

      src = File.read(file)
      unless single_constant_file?(src)
        raise Skip, "#{name}: #{file} defines multiple top-level constants; not reloadable"
      end

      [file, src]
    end

    # Same Zeitwerk-shape rule the SubjectFinder gate applies to the target
    # file: re-evaling a multi-constant file would re-run macros on constants
    # that were NOT removed (accumulation bugs).
    def single_constant_file?(source)
      result = Prism.parse(source)
      return false unless result.success?

      result.value.statements.body.count do |s|
        s.is_a?(Prism::ClassNode) || s.is_a?(Prism::ModuleNode)
      end == 1
    end

    def remove_constant(name)
      parts = name.split("::")
      leaf = parts.pop
      parent = parts.empty? ? Object : Object.const_get(parts.join("::"))
      parent.send(:remove_const, leaf)
    end
  end
end
```

Add to `lib/active_mutator.rb`, directly after the `inserter` require:

```ruby
require_relative "active_mutator/closure_reload"
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/closure_reload_spec.rb`
Expected: PASS. Then run the file twice in one process order-shuffled with the rest of the suite (next step) to prove the constant cleanup holds.

- [ ] **Step 5: Full suite + gate, commit**

`bundle exec rspec > /tmp/t5.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t5gate.out 2>&1; echo $?` — expect 0.

```bash
git add lib/active_mutator/closure_reload.rb lib/active_mutator.rb spec/active_mutator/closure_reload_spec.rb
git commit -m "feat: ClosureReload — whole-file closure reload for class-body mutants (#2)"
```

---

### Task 6: Worker routing + `skipped` status through the pipeline

**Files:**
- Modify: `lib/active_mutator/worker.rb`
- Modify: `lib/active_mutator/result.rb` (comment only)
- Modify: `lib/active_mutator/runner.rb` (cap wiring + drop the Task 3 temporary reject, add the config filter)
- Test: `spec/active_mutator/worker_spec.rb`

- [ ] **Step 1: Write failing tests**

Append to `spec/active_mutator/worker_spec.rb` (read the existing file first and reuse its fake-writer/mutation helpers; the tests below spell out full doubles in case none fit):

```ruby
  describe "class-body mutants" do
    def class_body_mutation
      subject = ActiveMutator::Subject.new(
        name: "Thing (class body)", file: "/tmp/thing.rb",
        byte_range: 0...10, line_range: 1..3,
        constant_scope: "Thing", kind: :class_body, sclass: false
      )
      ActiveMutator::Mutation.new(
        subject: subject,
        edit: ActiveMutator::Edit.new(range: 8...9, replacement: "2", description: "x", operator: "Literal"),
        original_snippet: "1", line: 2,
        mutated_file_source: "class Thing\n  X = 2\nend\n",
        mutated_def_source: "class Thing\n  X = 2\nend\n",
        mutated_def_line: 1
      )
    end

    it "routes class-body mutants through ClosureReload" do
      mutation = class_body_mutation
      expect_any_instance_of(ActiveMutator::ClosureReload).to receive(:call)
      expect_any_instance_of(ActiveMutator::Inserter).not_to receive(:insert)
      writer = StringIO.new
      allow_any_instance_of(RSpec::Core::Runner).to receive(:setup)
      allow_any_instance_of(RSpec::Core::Runner).to receive(:run_specs).and_return(0)
      allow_any_instance_of(described_class).to receive(:covering_groups).and_return([])
      described_class.run(mutation, [], writer)
      expect(writer.string).to include('"status":"survived"')
    end

    it "reports skipped with the reason when ClosureReload raises Skip" do
      mutation = class_body_mutation
      allow_any_instance_of(ActiveMutator::ClosureReload)
        .to receive(:call).and_raise(ActiveMutator::ClosureReload::Skip, "constant Thing not loaded")
      writer = StringIO.new
      allow_any_instance_of(RSpec::Core::Runner).to receive(:setup)
      described_class.run(mutation, [], writer)
      payload = JSON.parse(writer.string)
      expect(payload["status"]).to eq("skipped")
      expect(payload["details"]).to eq("constant Thing not loaded")
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/worker_spec.rb`
Expected: FAIL (Worker always uses Inserter; no skipped path).

- [ ] **Step 3: Implement**

`lib/active_mutator/worker.rb` — replace the `Inserter.new.insert(@mutation)` line inside `run` with:

```ruby
      insert_mutation                  # now the target constant exists
```

and change the rescue clause / add the private method:

```ruby
    rescue ClosureReload::Skip => e
      emit("skipped", details: e.message)
    rescue StandardError, ScriptError => e
      emit("error", details: "#{e.class}: #{e.message}")
    end

    private

    # Def mutants class_eval over the live constant; class-body mutants
    # cannot (macros accumulate) and go through whole-file closure reload.
    def insert_mutation
      if @mutation.subject.class_body?
        ClosureReload.new(@mutation.subject, @mutation.mutated_file_source).call
      else
        Inserter.new.insert(@mutation)
      end
    end
```

(The existing `private` keyword already exists — put `insert_mutation` under it and keep the rescue edits inside `run`.)

`lib/active_mutator/result.rb` — update the comment:

```ruby
  # status: :killed | :survived | :timeout | :error | :uncovered | :accepted | :skipped
```

`lib/active_mutator/runner.rb`:
1. Delete the Task 3 temporary line `subjects = subjects.reject(&:class_body?) # TODO(Task 6): ...` and replace it with the config gate:

```ruby
      subjects = subjects.reject(&:class_body?) unless @config.class_level
```

2. In `#call`, immediately after `load_operators`, wire the cap:

```ruby
      ClosureReload.cap = @config.class_level_closure_cap
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/worker_spec.rb spec/active_mutator/runner_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + gate, commit**

`bundle exec rspec > /tmp/t6.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t6gate.out 2>&1; echo $?` — expect 0.

NOTE: from this task on, the self-mutation gate itself runs with class-level mutation ON over `lib/` — class-body mutants of active_mutator's own files will appear. If the gate reports survivors that are genuine coverage gaps in our own suite, write the killing spec; if genuinely equivalent, report BLOCKED (do not accept). If runtime blows up (`lib` classes reloading mid-run), diagnose before proceeding — this is the first true dogfood of the feature.

- [ ] **Step 6: Commit**

```bash
git add lib/active_mutator/worker.rb lib/active_mutator/result.rb lib/active_mutator/runner.rb spec/active_mutator/worker_spec.rb
git commit -m "feat: Worker routes class-body mutants through ClosureReload; skipped status (#2)"
```

---

### Task 7: Phase-1 planning for class-body mutants

**Files:**
- Modify: `lib/active_mutator/runner.rb` (`plan_work` + helpers)
- Test: `spec/active_mutator/runner_spec.rb`

**Context:** Class-body lines execute at boot; the coverage map has no examples on them, so `plan_work`'s per-line lookup would mark every class-body mutant `uncovered`. Phase-1 set: examples covering ANY line of the subject's file (`map.examples_covering_file`) ∪ examples of the convention spec file (`app/models/user.rb` → `spec/models/user_spec.rb`; `lib/x/y.rb` → `spec/x/y_spec.rb`; anything else `<rel-minus-first-dir>` → `spec/<...>_spec.rb`).

- [ ] **Step 1: Write failing tests**

Append to `spec/active_mutator/runner_spec.rb` (the file unit-tests `plan_work` with a stub coverage map — read it and reuse its map-stub style; below assumes a `Config`-building helper exists, adapt as found):

```ruby
  describe "plan_work with class-body mutants" do
    def class_body_mutation(file)
      subject = ActiveMutator::Subject.new(
        name: "User (class body)", file: file,
        byte_range: 0...30, line_range: 1..3,
        constant_scope: "User", kind: :class_body, sclass: false
      )
      ActiveMutator::Mutation.new(
        subject: subject,
        edit: ActiveMutator::Edit.new(range: 14...18, replacement: "false", description: "replace `true` with `false`", operator: "Literal"),
        original_snippet: "true", line: 2,
        mutated_file_source: "x", mutated_def_source: "x", mutated_def_line: 1
      )
    end

    it "plans against file-covering examples plus the convention spec file" do
      root = "/proj"
      file = "/proj/app/models/user.rb"
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_covering_file).with(file).and_return(["./spec/requests/users_spec.rb[1:1]"])
      allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb").and_return(["./spec/models/user_spec.rb[1:1]"])
      allow(map).to receive(:time_for).and_return(0.1)
      runner = described_class.new(build_config(root: root))
      items, pre = runner.plan_work([class_body_mutation(file)], map)
      expect(pre).to be_empty
      expect(items.first.example_ids).to contain_exactly(
        "./spec/models/user_spec.rb[1:1]", "./spec/requests/users_spec.rb[1:1]"
      )
    end

    it "marks a class-body mutant uncovered when both sets are empty" do
      root = "/proj"
      file = "/proj/lib/thing.rb"
      map = instance_double(ActiveMutator::CoverageMap)
      allow(map).to receive(:examples_covering_file).with(file).and_return([])
      allow(map).to receive(:examples_for_spec_file).with("spec/thing_spec.rb").and_return([])
      runner = described_class.new(build_config(root: root))
      items, pre = runner.plan_work([class_body_mutation(file)], map)
      expect(items).to be_empty
      expect(pre.map(&:status)).to eq([:uncovered])
    end
  end
```

(`build_config` stands for however the existing spec constructs a `Config` — reuse the real helper. If none exists, build `ActiveMutator::CLI.parse([])` and `.with(root: root)`.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/runner_spec.rb`
Expected: FAIL (class-body mutants get per-line lookup → wrong set / uncovered).

- [ ] **Step 3: Implement**

In `lib/active_mutator/runner.rb` `plan_work`, replace the line

```ruby
        example_ids = map.examples_for(mutation.subject.file, coverage_lines(mutation))
```

with:

```ruby
        example_ids = examples_for_mutation(mutation, map)
```

and add the private helpers:

```ruby
    # Class-body lines execute at load time, so line coverage never
    # attributes examples to them. Substitute: every example that covers ANY
    # line of the file (it must have loaded the class), plus the convention
    # spec file's examples. Phase 2 (escalation) widens further before a
    # survivor is declared.
    def examples_for_mutation(mutation, map)
      return map.examples_for(mutation.subject.file, coverage_lines(mutation)) unless mutation.subject.class_body?

      (map.examples_covering_file(mutation.subject.file) |
        map.examples_for_spec_file(convention_spec_rel(mutation.subject.file))).sort
    end

    def convention_spec_rel(file)
      rel = file.delete_prefix(@config.root.chomp("/") + "/").delete_suffix(".rb")
      rest = rel.sub(%r{\A(app|lib)/}, "")
      "spec/#{rest}_spec.rb"
    end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/runner_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + gate, commit**

`bundle exec rspec > /tmp/t7.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t7gate.out 2>&1; echo $?` — expect 0.

```bash
git add lib/active_mutator/runner.rb spec/active_mutator/runner_spec.rb
git commit -m "feat: phase-1 example planning for class-body mutants (#2)"
```

---

### Task 8: Phase-2 escalation before declaring a survivor

**Files:**
- Modify: `lib/active_mutator/runner.rb`
- Test: `spec/active_mutator/runner_escalation_spec.rb` (new)

**Context:** After the scheduler run, class-body survivors get one escalation: spec files textually referencing the subject file's constants (same regex approach as `BaselineDelta.newly_covering_candidates`, reusing `DefinedConstants`), minus files already covered in phase 1, converted to example ids via `map.examples_for_spec_file`. Non-empty → re-enqueue through the same scheduler; the escalated result replaces the phase-1 `survived`. A mutant that survives escalation carries `details: "escalated (+N spec files)"`. Empty escalation set → the phase-1 survivor stands unchanged.

- [ ] **Step 1: Write failing tests**

Create `spec/active_mutator/runner_escalation_spec.rb`:

```ruby
require "tmpdir"

RSpec.describe ActiveMutator::Runner do
  def class_body_mutation(file)
    subject = ActiveMutator::Subject.new(
      name: "User (class body)", file: file,
      byte_range: 0...30, line_range: 1..3,
      constant_scope: "User", kind: :class_body, sclass: false
    )
    ActiveMutator::Mutation.new(
      subject: subject,
      edit: ActiveMutator::Edit.new(range: 14...18, replacement: "false",
                                    description: "replace `true` with `false`", operator: "Literal"),
      original_snippet: "true", line: 2,
      mutated_file_source: "x", mutated_def_source: "x", mutated_def_line: 1
    )
  end

  def result(mutation, status, details: nil)
    ActiveMutator::Result.new(mutation: mutation, status: status, details: details)
  end

  around do |ex|
    Dir.mktmpdir do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "app/models"))
      FileUtils.mkdir_p(File.join(root, "spec/models"))
      FileUtils.mkdir_p(File.join(root, "spec/requests"))
      File.write(File.join(root, "app/models/user.rb"), "class User\n  validates :email, presence: true\nend\n")
      File.write(File.join(root, "spec/models/user_spec.rb"), "RSpec.describe User do\nend\n")
      File.write(File.join(root, "spec/requests/signup_spec.rb"), "RSpec.describe \"signup\" do\n  it { User }\nend\n")
      ex.run
    end
  end

  let(:config) { ActiveMutator::CLI.parse([]).with(root: @root) }
  let(:runner) { described_class.new(config, reporter: instance_double(ActiveMutator::Reporter::Terminal, on_result: nil)) }

  it "re-runs class-body survivors against referencing spec files and takes the escalated verdict" do
    file = File.join(@root, "app/models/user.rb")
    mutation = class_body_mutation(file)
    map = instance_double(ActiveMutator::CoverageMap)
    # Phase 1 covered only the convention file:
    allow(map).to receive(:examples_for_spec_file).with("spec/models/user_spec.rb")
                                                  .and_return(["./spec/models/user_spec.rb[1:1]"])
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/signup_spec.rb")
                                                  .and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).to receive(:run) do |items|
      expect(items.size).to eq(1)
      expect(items.first.example_ids).to eq(["./spec/requests/signup_spec.rb[1:1]"])
      [result(mutation, :killed)]
    end

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map,
      phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
    )
    expect(results.map(&:status)).to eq([:killed])
  end

  it "annotates a mutant that survives escalation" do
    file = File.join(@root, "app/models/user.rb")
    mutation = class_body_mutation(file)
    map = instance_double(ActiveMutator::CoverageMap)
    allow(map).to receive(:examples_for_spec_file).with("spec/requests/signup_spec.rb")
                                                  .and_return(["./spec/requests/signup_spec.rb[1:1]"])
    allow(map).to receive(:time_for).and_return(0.1)
    scheduler = instance_double(ActiveMutator::Scheduler, run: [result(mutation, :survived)])

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map,
      phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
    )
    expect(results.first.status).to eq(:survived)
    expect(results.first.details).to eq("escalated (+1 spec files)")
  end

  it "leaves the survivor untouched when no extra spec files reference the constant" do
    file = File.join(@root, "app/models/user.rb")
    File.write(File.join(@root, "spec/requests/signup_spec.rb"), "RSpec.describe \"signup\" do\nend\n")
    mutation = class_body_mutation(file)
    map = instance_double(ActiveMutator::CoverageMap)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).not_to receive(:run)

    results = runner.escalate_class_body_survivors(
      [result(mutation, :survived)], scheduler, map,
      phase1_ids: { mutation => ["./spec/models/user_spec.rb[1:1]"] }
    )
    expect(results.first.status).to eq(:survived)
    expect(results.first.details).to be_nil
  end

  it "does not touch non-class-body survivors" do
    file = File.join(@root, "app/models/user.rb")
    mutation = class_body_mutation(file)
    def_subject = mutation.subject.with(kind: :instance, name: "User#x")
    def_mutation = mutation.with(subject: def_subject)
    map = instance_double(ActiveMutator::CoverageMap)
    scheduler = instance_double(ActiveMutator::Scheduler)
    expect(scheduler).not_to receive(:run)

    results = runner.escalate_class_body_survivors([result(def_mutation, :survived)], scheduler, map, phase1_ids: {})
    expect(results.map(&:status)).to eq([:survived])
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/runner_escalation_spec.rb`
Expected: FAIL — `escalate_class_body_survivors` undefined.

- [ ] **Step 3: Implement**

In `lib/active_mutator/runner.rb`:

1. `plan_work` must expose phase-1 ids for escalation. Change its signature/return: it already returns `[items, pre_results]`; add a third element — replace the final `[items, pre_results]` with:

```ruby
      phase1_ids = items.to_h { |i| [i.mutation, i.example_ids] }
      [items, pre_results, phase1_ids]
```

and update the two call sites: in `#call`, `items, pre_results, phase1_ids = plan_work(...)`; in existing `plan_work` unit specs, destructuring with two names still works in Ruby (extra element ignored in multiple assignment with two vars? NO — `a, b = [1,2,3]` assigns a=1,b=2 and drops 3 — fine, existing specs keep passing).

2. In `#call`, after `results = scheduler.run(items) + pre_results` add:

```ruby
      results = escalate_class_body_survivors(results, scheduler, map, phase1_ids: phase1_ids)
```

3. Add the public method and private helpers:

```ruby
    # Phase 2 of the class-body kill pipeline (public for unit testing).
    # A class-body survivor is only DECLARED after every spec file that
    # references the constant has had its shot: re-enqueue against the
    # referencing files phase 1 didn't run, and take the escalated verdict.
    def escalate_class_body_survivors(results, scheduler, map, phase1_ids:)
      candidates = results.select { |r| r.status == :survived && r.mutation.subject.class_body? }
      return results if candidates.empty?

      spec_contents = Dir[File.join(@config.root, "spec/**/*_spec.rb")].to_h { |f| [f, File.read(f)] }
      items = {}
      candidates.each do |r|
        ids = escalation_examples(r.mutation, map, spec_contents, phase1_ids.fetch(r.mutation, []))
        next if ids.empty?

        lane = ids.any? { |id| serial_example?(id) } ? :serial : :parallel
        variable = map.time_for(ids) * @config.timeout_factor
        boot_extra = lane == :serial ? @config.browser_boot_seconds : 0.0
        items[r.mutation] = WorkItem.new(mutation: r.mutation, example_ids: ids,
                                         timeout: variable + @config.timeout_floor + boot_extra,
                                         lane: lane, variable: variable)
      end
      return results if items.empty?

      escalated = scheduler.run(items.values).to_h { |r| [r.mutation, r] }
      results.map do |r|
        replacement = escalated[r.mutation]
        next r unless r.status == :survived && replacement

        if replacement.status == :survived
          extra = items[r.mutation].example_ids.map { |id| id[/\A(.+?)\[/, 1] }.uniq.size
          replacement.with(details: "escalated (+#{extra} spec files)")
        else
          replacement
        end
      end
    end

    private

    # Spec files that textually reference a constant the subject's file
    # defines (same approach as BaselineDelta.newly_covering_candidates),
    # minus everything phase 1 already ran; returned as example ids.
    def escalation_examples(mutation, map, spec_contents, phase1)
      constants = DefinedConstants.in_source(File.read(mutation.subject.file))
      return [] if constants.empty?

      pattern = /\b(?:#{constants.map { |c| Regexp.escape(c) }.join("|")})\b/
      phase1_files = phase1.map { |id| id.sub(%r{\A\./}, "").sub(/\[.*\]\z/, "") }.uniq
      spec_contents.filter_map do |abs, content|
        rel = abs.delete_prefix(@config.root.chomp("/") + "/")
        next if phase1_files.include?(rel)
        next unless content.match?(pattern)

        map.examples_for_spec_file(rel)
      end.flatten.uniq.sort
    end
```

Place `escalate_class_body_survivors` ABOVE the `private` keyword (it is unit-tested directly, like `plan_work` and `exit_code`); `escalation_examples` goes below it.

Also update `debug_plan`'s caller — `#call` destructures three values now; `debug_plan(items, pre_results)` is unchanged.

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/runner_escalation_spec.rb spec/active_mutator/runner_spec.rb`
Expected: PASS (including pre-existing plan_work specs).

- [ ] **Step 5: Full suite + gate, commit**

`bundle exec rspec > /tmp/t8.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t8gate.out 2>&1; echo $?` — expect 0.

```bash
git add lib/active_mutator/runner.rb spec/active_mutator/runner_escalation_spec.rb
git commit -m "feat: escalate class-body survivors to constant-referencing specs (#2)"
```

---

### Task 9: Reporter surface for `skipped` and escalation

**Files:**
- Modify: `lib/active_mutator/reporter/terminal.rb`
- Modify: `lib/active_mutator/reporter/stryker_json.rb`
- Test: `spec/active_mutator/reporter/terminal_spec.rb`, `spec/active_mutator/reporter/stryker_json_spec.rb`

- [ ] **Step 1: Write failing tests**

Append to `spec/active_mutator/reporter/terminal_spec.rb` (reuse its existing result-building helpers; adapt names to what the file actually defines):

```ruby
  it "prints '-' for skipped and lists skip reasons in the summary" do
    skipped = build_result(status: :skipped, details: "reload closure (12 constants) exceeds cap (10)")
    out = StringIO.new
    reporter = described_class.new(out: out)
    reporter.on_result(skipped)
    reporter.summary([skipped], invalid_count: 0)
    expect(out.string).to include("-")
    expect(out.string).to include("skipped: 1")
    expect(out.string).to include("Skipped mutants (not counted in the score):")
    expect(out.string).to include("reload closure (12 constants) exceeds cap (10)")
  end

  it "excludes skipped from the mutation score" do
    results = [build_result(status: :killed), build_result(status: :skipped, details: "x")]
    out = StringIO.new
    described_class.new(out: out).summary(results, invalid_count: 0)
    expect(out.string).to include("Mutation score: 100.0%")
  end

  it "shows the escalation annotation on survivors" do
    survivor = build_result(status: :survived, details: "escalated (+3 spec files)")
    out = StringIO.new
    described_class.new(out: out).summary([survivor], invalid_count: 0)
    expect(out.string).to include("escalated (+3 spec files)")
  end
```

Append to `spec/active_mutator/reporter/stryker_json_spec.rb`:

```ruby
  it "maps skipped to Ignored with the reason" do
    result = build_result(status: :skipped, details: "constant not loaded")
    report = generate_report([result])
    mutant = report["files"].values.first["mutants"].first
    expect(mutant["status"]).to eq("Ignored")
    expect(mutant["statusReason"]).to eq("constant not loaded")
  end
```

(`build_result`/`generate_report` = whatever helpers those spec files already use; read them first and match.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/active_mutator/reporter/terminal_spec.rb spec/active_mutator/reporter/stryker_json_spec.rb`
Expected: FAIL (`CHARS.fetch(:skipped)` KeyError; STATUS.fetch KeyError).

- [ ] **Step 3: Implement**

`lib/active_mutator/reporter/terminal.rb`:

1. Extend CHARS:

```ruby
      CHARS = { killed: ".", survived: "S", timeout: "T", error: "E",
                uncovered: "U", accepted: "A", skipped: "-" }.freeze
```

2. In `summary`, after the survivors block, add the skipped block:

```ruby
        skipped = results.select { |r| r.status == :skipped }
        print_skipped(skipped) unless skipped.empty?
```

3. In `print_survivors`, append the annotation after the `+` line:

```ruby
          @out.puts "    (#{result.details})" if result.details
```

4. Add the private method:

```ruby
      def print_skipped(skipped)
        @out.puts "", "Skipped mutants (not counted in the score):"
        skipped.each do |result|
          m = result.mutation
          @out.puts "  #{m.subject.name} (#{m.subject.file}:#{m.line}): #{result.details}"
        end
      end
```

(`score` already counts only killed/timeout/survived — no change needed; the new spec pins that.)

`lib/active_mutator/reporter/stryker_json.rb` — extend STATUS:

```ruby
      STATUS = { killed: "Killed", survived: "Survived", timeout: "Timeout",
                 error: "RuntimeError", uncovered: "NoCoverage",
                 accepted: "Ignored", skipped: "Ignored" }.freeze
```

(`statusReason` already flows from `result.details`; the JSON reporter serializes status strings generically — no change.)

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/active_mutator/reporter/`
Expected: PASS.

- [ ] **Step 5: Full suite + gate, commit**

`bundle exec rspec > /tmp/t9.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t9gate.out 2>&1; echo $?` — expect 0.

```bash
git add lib/active_mutator/reporter/terminal.rb lib/active_mutator/reporter/stryker_json.rb spec/active_mutator/reporter/
git commit -m "feat: report skipped mutants and escalation annotations (#2)"
```

---

### Task 10: E2E fixture — kill a validates deletion for real

**Files:**
- Create: `spec/fixtures/class_level_project/` (Gemfile, lib, spec)
- Test: `spec/e2e/class_level_project_spec.rb` (new)

**Context:** Follow the existing `spec/fixtures/tiny_project/` + `spec/e2e/tiny_project_spec.rb` pattern EXACTLY (read both first: how the fixture Gemfile points at the gem under test, how the e2e spec shells out with `Bundler.with_unbundled_env`, what it asserts on). The new fixture is plain Ruby with a hand-rolled `validates`-style macro (no Rails dependency), a concern-style module, and specs that kill some class-level mutants while leaving one to survive-then-annotate.

- [ ] **Step 1: Create the fixture**

`spec/fixtures/class_level_project/Gemfile`:

```ruby
source "https://rubygems.org"

gem "active_mutator", path: "../../.."
gem "rspec"
```

`spec/fixtures/class_level_project/lib/model_base.rb`:

```ruby
# Minimal validates-style macro so the fixture exercises real macro
# accumulation semantics without a Rails dependency.
class ModelBase
  def self.validations = @validations ||= []

  def self.validates(field, presence: false)
    validations << [field, presence]
  end

  def valid?
    self.class.validations.all? do |field, presence|
      !presence || !send(field).to_s.empty?
    end
  end
end
```

`spec/fixtures/class_level_project/lib/auditable.rb`:

```ruby
module Auditable
  AUDIT_PREFIX = "audit"

  def audit_tag
    "#{AUDIT_PREFIX}:#{self.class.name}"
  end
end
```

`spec/fixtures/class_level_project/lib/user.rb`:

```ruby
require_relative "model_base"
require_relative "auditable"

class User < ModelBase
  include Auditable

  validates :email, presence: true

  attr_accessor :email

  def initialize(email)
    @email = email
  end
end
```

`spec/fixtures/class_level_project/spec/spec_helper.rb`:

```ruby
require_relative "../lib/user"
```

`spec/fixtures/class_level_project/spec/user_spec.rb`:

```ruby
require "spec_helper"

RSpec.describe User do
  it "is invalid without an email" do
    expect(User.new("").valid?).to be(false)
  end

  it "is valid with an email" do
    expect(User.new("a@b.c").valid?).to be(true)
  end

  it "tags audits with the audit prefix" do
    expect(User.new("a@b.c").audit_tag).to eq("audit:User")
  end
end
```

- [ ] **Step 2: Write the e2e spec**

Create `spec/e2e/class_level_project_spec.rb`, following the tiny_project e2e spec's structure (bundle install in fixture, run `active_mutator lib`, assert on output). Assertions:

```ruby
# Within the run-output assertions:
# 1. The class-body deletion of `validates :email, presence: true` in user.rb
#    and the flip `presence: true` -> `presence: false` are KILLED (the two
#    valid?/invalid specs pin them).
# 2. The module class-body mutant replacing "audit" with "" in auditable.rb
#    is KILLED — this proves closure reload propagated a MODULE mutation
#    through include (User must be reloaded for audit_tag to change).
# 3. Exit code and score line are consistent with whatever survivors remain;
#    assert killed-count >= 3 rather than an exact score (operator catalog
#    growth must not break this test).
expect(output).to match(/User \(class body\)/)
expect(output).to match(/Auditable \(class body\)/)
```

Also assert the run does NOT contain `error:` counts > 0 (`expect(output).to match(/^error: 0$/)`).

NOTE for the implementer: `user.rb` has `require_relative` lines at the top — top-level statements are fine (the Zeitwerk gate counts class/module nodes, not all statements). ClosureReload re-evals `user.rb` when `Auditable` mutants reload the closure: the `require_relative` lines are no-ops on re-eval (already in `$LOADED_FEATURES`), which is exactly the desired semantics — and a load-bearing property this e2e test proves.

- [ ] **Step 3: Run the e2e spec**

Run: `bundle exec rspec spec/e2e/class_level_project_spec.rb > /tmp/t10.out 2>&1; echo $?`
Expected: exit 0. This is the highest-risk task in the plan — the first full-pipeline proof of closure reload. If mutants error out, debug via the fixture directly: `cd spec/fixtures/class_level_project && bundle exec active_mutator lib --debug-plan`.

- [ ] **Step 4: Full suite + gate, commit**

`bundle exec rspec > /tmp/t10full.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t10gate.out 2>&1; echo $?` — expect 0.

```bash
git add spec/fixtures/class_level_project spec/e2e/class_level_project_spec.rb
git commit -m "test: e2e fixture proving class-level mutation through closure reload (#2)"
```

---

### Task 11: Docs sweep

**Files:**
- Modify: `README.md` (scope-honesty section)
- Modify: `docs/guides/how-it-works.md`
- Modify: `docs/guides/operators.md`
- Modify: `docs/guides/custom-operators.md`

- [ ] **Step 1: README**

Rewrite the known-limits paragraph: class-level code (macros, constants, scope lambdas) IS now mutated via class-body subjects and closure reload; remaining limits — non-Zeitwerk files (multi-constant, monkey-patches: #32), defs/code inside blocks (#31), constant-object captures (`USER_CLASS = User`) hold stale references. Mention `--no-class-level` and the `skipped` status.

- [ ] **Step 2: how-it-works.md**

Add a section "Class-level mutation: closure reload" after the insertion section covering: why class_eval can't re-run macros (accumulation), the remove_const + whole-file re-eval strategy, the ObjectSpace closure (includers/extenders/subclasses), per-member guards and the `skipped` status, the cap (`class_level_closure_cap`), and the two-phase kill pipeline (boot-time lines have no line coverage → file-covering + convention set, then constant-reference escalation). Update the "Honest limits" section to match the README.

- [ ] **Step 3: operators.md + custom-operators.md**

`operators.md`: add a short paragraph in the intro — operators now also run over class-body nodes (macro arguments, constants, scope lambdas); a StatementDeletion survivor on a `validates` line means no test exercises that validation.
`custom-operators.md`: one added note — custom operators automatically apply to class-body nodes; no API change.

- [ ] **Step 4: Verify docs accuracy against implementation**

Re-read the final `subject_finder.rb`, `closure_reload.rb`, `runner.rb` and confirm every documented claim (defaults, flag names, statuses) matches the code. Fix mismatches in the DOCS, not the code.

- [ ] **Step 5: Full suite + gate, commit**

`bundle exec rspec > /tmp/t11.out 2>&1; echo $?` — expect 0.
`bundle exec exe/active_mutator lib --changed > /tmp/t11gate.out 2>&1; echo $?` — expect 0.

```bash
git add README.md docs/guides/
git commit -m "docs: class-level mutation — closure reload, skipped status, limits (#2)"
```
