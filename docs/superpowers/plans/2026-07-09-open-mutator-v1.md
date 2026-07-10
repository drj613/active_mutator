# open_mutator v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build open_mutator v1 — a pure-Ruby, Prism-based mutation testing tool with RSpec integration, source-span mutations, coverage-based test selection, and a fork-pool kill pipeline.

**Architecture:** Six components in a one-directional pipeline: CLI/Config → Subject Finder → Mutation Engine → Scheduler/Workers → Reporter, fed by a cached Coverage Map from an instrumented baseline run. Mutations are text edits `(byte_range, replacement)` spliced into the original source — no AST unparsing anywhere. Workers are forks of a preloaded parent; a mutated `def` is re-eval'd in its constant scope, covering examples run in-process, and exit status decides kill.

**Tech Stack:** Ruby ≥ 3.2 (`Data.define`, `fork`), `prism` gem (parsing), `rspec-core` (host-project integration + our own test suite), stdlib `Coverage`, `json`, `digest`, `optparse`.

**Spec:** `docs/superpowers/specs/2026-07-09-open-mutator-design.md`

---

## File structure

```
open_mutator.gemspec
Gemfile
.rspec
exe/open_mutator                        # binstub → CLI
lib/open_mutator.rb                     # requires + module root
lib/open_mutator/version.rb
lib/open_mutator/edit.rb                # Edit value object
lib/open_mutator/splicer.rb             # byte-range splicing
lib/open_mutator/subject.rb             # Subject value object
lib/open_mutator/subject_finder.rb      # Prism visitor → [Subject]
lib/open_mutator/mutation.rb            # Mutation value object
lib/open_mutator/analysis.rb            # Analysis value object (mutations + invalid count)
lib/open_mutator/operators/base.rb      # operator superclass + registry
lib/open_mutator/operators/conditional_boundary.rb
lib/open_mutator/operators/condition_forcing.rb
lib/open_mutator/operators/logical_operator.rb
lib/open_mutator/operators/literal.rb
lib/open_mutator/operators/statement_deletion.rb
lib/open_mutator/operators/early_return.rb
lib/open_mutator/operators/call_swap.rb
lib/open_mutator/operators/negation_removal.rb
lib/open_mutator/engine.rb              # subject → Analysis (validity gate here)
lib/open_mutator/baseline_hooks.rb      # loaded STANDALONE via RUBYOPT=-r…; never required by lib/open_mutator.rb (it starts Coverage)
lib/open_mutator/coverage_map.rb        # inverted index wrapper
lib/open_mutator/baseline.rb            # baseline subprocess runner + cache
lib/open_mutator/inserter.rb            # eval mutated def into constant scope
lib/open_mutator/worker.rb              # runs inside fork
lib/open_mutator/work_item.rb           # WorkItem value object
lib/open_mutator/result.rb              # Result value object
lib/open_mutator/scheduler.rb           # fork pool + deadlines
lib/open_mutator/reporter/terminal.rb
lib/open_mutator/reporter/json.rb
lib/open_mutator/since_filter.rb        # git diff → changed lines
lib/open_mutator/config.rb
lib/open_mutator/runner.rb              # orchestration
lib/open_mutator/cli.rb                 # optparse → Config → Runner
spec/spec_helper.rb
spec/support/operator_helper.rb
spec/open_mutator/**/*_spec.rb          # one spec file per lib file
spec/fixtures/tiny_project/             # plain-Ruby fixture (baseline + E2E)
spec/fixtures/rails_app/                # minimal Rails fixture (Phase 6)
spec/property/reparse_spec.rb           # property gate
spec/e2e/tiny_project_spec.rb
spec/e2e/rails_app_spec.rb
```

**Core type signatures (canonical — later tasks must match):**

```ruby
Edit     = Data.define(:range, :replacement, :description)      # range: exclusive byte Range
Subject  = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind)  # kind: :instance | :singleton
Mutation = Data.define(:subject, :edit, :original_snippet, :line,
                       :mutated_file_source, :mutated_def_source, :mutated_def_line)
Analysis = Data.define(:mutations, :invalid_count)
WorkItem = Data.define(:mutation, :example_ids, :timeout)
Result   = Data.define(:mutation, :status, :details)            # status: :killed :survived :timeout :error :uncovered

Splicer.apply(source, edits)                     → String
SubjectFinder.call(file)                         → [Subject]
Operators::Base#edits(node)                      → [Edit];  Operators::Base.all → [operator instances]
Engine#analyze(subject, source: File.read(...))  → Analysis
CoverageMap.load(path); #examples_for(file, lines) → [String]; #time_for(example_ids) → Float; #fresh?(digests) → bool
Baseline.new(root:, cache_dir:); #coverage_map(force: false) → CoverageMap
Inserter#insert(mutation)                        → nil (side effect: redefines method)
Worker.run(mutation, example_ids, writer)        → nil (writes JSON line to writer)
Scheduler.new(jobs:, worker:, on_result:); #run(items) → [Result]
Reporter::Terminal / Reporter::Json: #on_result(result); #summary(results, invalid_count:)
SinceFilter.new(ref:, root:); #cover?(subject) → bool; SinceFilter.parse(diff_text) → {path => [lines]}
CLI.run(argv)                                    → Integer exit code
Runner.new(config, reporter: nil); #call         → Integer exit code
```

---

# Phase 1 — Foundation

## Task 1: Gem scaffold

**Files:**
- Create: `open_mutator.gemspec`, `Gemfile`, `.rspec`, `.gitignore`, `lib/open_mutator.rb`, `lib/open_mutator/version.rb`, `exe/open_mutator`, `spec/spec_helper.rb`

- [x] **Step 1: Write scaffold files**

`open_mutator.gemspec`:
```ruby
require_relative "lib/open_mutator/version"

Gem::Specification.new do |spec|
  spec.name = "open_mutator"
  spec.version = OpenMutator::VERSION
  spec.summary = "Mutation testing for Ruby, built on Prism"
  spec.description = "Open-source mutation testing with source-span mutations, coverage-based test selection, and a fork-pool kill pipeline. Rails-first."
  spec.authors = ["Daniel John"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "LICENSE*", "README*"]
  spec.bindir = "exe"
  spec.executables = ["open_mutator"]
  spec.add_dependency "prism", ">= 0.30"
  spec.add_dependency "rspec-core", ">= 3.12" # worker + baseline_hooks require it at runtime
  spec.add_development_dependency "rspec", "~> 3.13"
end
```

`Gemfile`:
```ruby
source "https://rubygems.org"
gemspec
```

`.rspec`:
```
--require spec_helper
--color
```

`.gitignore`:
```
.open_mutator/
spec/fixtures/*/Gemfile.lock
spec/fixtures/*/.open_mutator/
Gemfile.lock
*.gem
```

`lib/open_mutator/version.rb`:
```ruby
module OpenMutator
  VERSION = "0.1.0"
end
```

`lib/open_mutator.rb` (requires grow as files are created; each later task appends its lines here):
```ruby
require "prism"

require_relative "open_mutator/version"

module OpenMutator
  Error = Class.new(StandardError)
  BaselineFailed = Class.new(Error)
end
```

`exe/open_mutator`:
```ruby
#!/usr/bin/env ruby
require "open_mutator"

exit OpenMutator::CLI.run(ARGV)
```

`spec/spec_helper.rb`:
```ruby
require "open_mutator"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  # Slow suites are opt-in:
  config.filter_run_excluding :integration unless ENV["OPEN_MUTATOR_INTEGRATION"]
  config.filter_run_excluding :e2e unless ENV["OPEN_MUTATOR_E2E"]
  config.filter_run_excluding :rails_e2e unless ENV["OPEN_MUTATOR_RAILS_E2E"]
end
```

- [x] **Step 2: Install and verify**

Run: `cd /Users/djdjo/Documents/enovis/open_mutator && chmod +x exe/open_mutator && bundle install && bundle exec rspec`
Expected: `0 examples, 0 failures`

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "chore: gem scaffold"
```

## Task 2: Edit + Splicer

**Files:**
- Create: `lib/open_mutator/edit.rb`, `lib/open_mutator/splicer.rb`
- Test: `spec/open_mutator/splicer_spec.rb`

- [x] **Step 1: Write the failing tests**

`spec/open_mutator/splicer_spec.rb`:
```ruby
RSpec.describe OpenMutator::Splicer do
  def edit(range, replacement)
    OpenMutator::Edit.new(range: range, replacement: replacement, description: "test")
  end

  it "replaces a byte range" do
    expect(described_class.apply("a >= b", [edit(2...4, ">")])).to eq("a > b")
  end

  it "applies multiple edits without offset drift" do
    src = "x + y + z"
    edits = [edit(0...1, "AA"), edit(8...9, "BB")]
    expect(described_class.apply(src, edits)).to eq("AA + y + BB")
  end

  it "splices bytewise in multibyte source" do
    src = %(name = "héllo"\nn > 0)
    # "é" is 2 bytes; ">" sits at byte offset 18
    expect(src.byteslice(18, 1)).to eq(">")
    expect(described_class.apply(src, [edit(18...19, ">=")])).to eq(%(name = "héllo"\nn >= 0))
  end

  it "preserves the source encoding" do
    out = described_class.apply("a > b", [edit(2...3, ">=")])
    expect(out.encoding).to eq(Encoding::UTF_8)
    expect(out).to be_valid_encoding
  end

  it "supports deletion via empty replacement" do
    expect(described_class.apply("a + b", [edit(1...5, "")])).to eq("a")
  end
end
```

- [x] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/splicer_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Splicer`

- [x] **Step 3: Implement**

`lib/open_mutator/edit.rb`:
```ruby
module OpenMutator
  # A single mutation as a text edit: replace `range` (exclusive byte Range)
  # in the original source with `replacement`.
  Edit = Data.define(:range, :replacement, :description)
end
```

`lib/open_mutator/splicer.rb`:
```ruby
module OpenMutator
  module Splicer
    # Applies edits to source by byte offset. Edits are applied back-to-front
    # so earlier offsets never drift.
    def self.apply(source, edits)
      bytes = source.b
      edits.sort_by { |e| -e.range.begin }.each do |e|
        bytes[e.range] = e.replacement.b
      end
      bytes.force_encoding(source.encoding)
    end
  end
end
```

Append to `lib/open_mutator.rb` after the module block:
```ruby
require_relative "open_mutator/edit"
require_relative "open_mutator/splicer"
```

- [x] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/splicer_spec.rb`
Expected: 5 examples, 0 failures

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Edit value object and byte-range splicer"
```

## Task 3: Subject + SubjectFinder

**Files:**
- Create: `lib/open_mutator/subject.rb`, `lib/open_mutator/subject_finder.rb`
- Test: `spec/open_mutator/subject_finder_spec.rb`

- [x] **Step 1: Write the failing tests**

`spec/open_mutator/subject_finder_spec.rb`:
```ruby
require "tmpdir"

RSpec.describe OpenMutator::SubjectFinder do
  def subjects_of(source)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      described_class.call(file)
    end
  end

  it "finds instance methods with constant scope" do
    subjects = subjects_of(<<~RUBY)
      module Billing
        class Calculator
          def total(items)
            items.sum
          end
        end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Billing::Calculator#total"])
    subject = subjects.first
    expect(subject.constant_scope).to eq("Billing::Calculator")
    expect(subject.kind).to eq(:instance)
    expect(subject.line_range).to eq(3..5)
  end

  it "finds singleton methods (def self.x)" do
    subjects = subjects_of(<<~RUBY)
      class Widget
        def self.build
          new
        end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Widget.build"])
    expect(subjects.first.kind).to eq(:singleton)
  end

  it "handles compact class paths and nesting" do
    subjects = subjects_of(<<~RUBY)
      class Foo::Bar
        module Baz
          def go = 1
        end
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Foo::Bar::Baz#go"])
  end

  it "records top-level defs under Object" do
    subjects = subjects_of("def helper\n  1\nend\n")
    expect(subjects.map(&:name)).to eq(["Object#helper"])
    expect(subjects.first.constant_scope).to be_nil
  end

  it "skips class << self bodies (documented v1 limit)" do
    subjects = subjects_of(<<~RUBY)
      class Widget
        class << self
          def hidden = 1
        end
        def visible = 2
      end
    RUBY
    expect(subjects.map(&:name)).to eq(["Widget#visible"])
  end

  it "records byte_range covering the whole def" do
    source = "class A\n  def b\n    1\n  end\nend\n"
    subject = subjects_of(source).first
    expect(source.byteslice(subject.byte_range)).to eq("def b\n    1\n  end")
  end

  it "returns [] for unparseable files" do
    expect(subjects_of("def broken(")).to eq([])
  end
end
```

- [x] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/subject_finder_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::SubjectFinder`

- [x] **Step 3: Implement**

`lib/open_mutator/subject.rb`:
```ruby
module OpenMutator
  # A mutable unit: one method definition.
  # byte_range/line_range cover the whole `def ... end`.
  Subject = Data.define(:name, :file, :byte_range, :line_range, :constant_scope, :kind) do
    def singleton? = kind == :singleton
  end
end
```

`lib/open_mutator/subject_finder.rb`:
```ruby
module OpenMutator
  class SubjectFinder < Prism::Visitor
    def self.call(file)
      result = Prism.parse(File.read(file))
      return [] unless result.success?

      finder = new(file)
      finder.visit(result.value)
      finder.subjects
    end

    attr_reader :subjects

    def initialize(file)
      @file = file
      @stack = []
      @subjects = []
      super()
    end

    def visit_class_node(node)
      with_scope(node.constant_path.slice) { super }
    end

    def visit_module_node(node)
      with_scope(node.constant_path.slice) { super }
    end

    # `class << self` bodies are a documented v1 limit: not visited.
    def visit_singleton_class_node(node); end

    def visit_def_node(node)
      singleton = node.receiver.is_a?(Prism::SelfNode)
      scope = @stack.empty? ? nil : @stack.join("::")
      loc = node.location
      @subjects << Subject.new(
        name: "#{scope || "Object"}#{singleton ? "." : "#"}#{node.name}",
        file: @file,
        byte_range: loc.start_offset...loc.end_offset,
        line_range: loc.start_line..loc.end_line,
        constant_scope: scope,
        kind: singleton ? :singleton : :instance
      )
      # No `super`: nested defs are out of scope for v1.
    end

    private

    def with_scope(name)
      @stack.push(name)
      yield
    ensure
      @stack.pop
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/subject"
require_relative "open_mutator/subject_finder"
```

- [x] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/subject_finder_spec.rb`
Expected: 7 examples, 0 failures

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Subject and Prism-based SubjectFinder"
```

---

# Phase 2 — Mutation Engine

## Task 4: Operator base, registry, and ConditionalBoundary

**Files:**
- Create: `lib/open_mutator/operators/base.rb`, `lib/open_mutator/operators/conditional_boundary.rb`
- Create: `spec/support/operator_helper.rb`
- Test: `spec/open_mutator/operators/conditional_boundary_spec.rb`

- [x] **Step 1: Write the shared operator test helper**

`spec/support/operator_helper.rb`:
```ruby
# Runs one operator over every node of a source snippet and returns the
# mutated source strings — golden-test style.
module OperatorHelper
  def mutations_of(source, operator)
    result = Prism.parse(source)
    raise "fixture does not parse: #{source.inspect}" unless result.success?

    edits = []
    each_node(result.value) { |node| edits.concat(operator.edits(node)) }
    edits.map { |e| OpenMutator::Splicer.apply(source, [e]) }
  end

  def each_node(node, &blk)
    yield node
    node.compact_child_nodes.each { |child| each_node(child, &blk) }
  end
end

RSpec.configure { |c| c.include OperatorHelper }
```

- [x] **Step 2: Write the failing tests**

`spec/open_mutator/operators/conditional_boundary_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::ConditionalBoundary do
  subject(:operator) { described_class.new }

  it "widens and narrows comparison operators" do
    expect(mutations_of("a > b", operator)).to eq(["a >= b"])
    expect(mutations_of("a >= b", operator)).to eq(["a > b"])
    expect(mutations_of("a < b", operator)).to eq(["a <= b"])
    expect(mutations_of("a <= b", operator)).to eq(["a < b"])
  end

  it "ignores non-comparison calls" do
    expect(mutations_of("a.push(b)", operator)).to eq([])
  end

  it "ignores unary/receiverless forms" do
    expect(mutations_of("puts(1)", operator)).to eq([])
  end

  it "registers itself" do
    expect(OpenMutator::Operators::Base.all.map(&:class)).to include(described_class)
  end
end
```

- [x] **Step 3: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/operators/conditional_boundary_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Operators`

- [x] **Step 4: Implement**

`lib/open_mutator/operators/base.rb`:
```ruby
module OpenMutator
  module Operators
    class Base
      REGISTRY = []

      def self.inherited(klass)
        super
        REGISTRY << klass
      end

      def self.all = REGISTRY.map(&:new)

      # Returns [Edit] for this node, or [] when the operator does not apply.
      def edits(node) = []

      private

      def loc_range(loc) = loc.start_offset...loc.end_offset

      def edit(range, replacement, description)
        Edit.new(range: range, replacement: replacement, description: description)
      end
    end
  end
end
```

`lib/open_mutator/operators/conditional_boundary.rb`:
```ruby
module OpenMutator
  module Operators
    class ConditionalBoundary < Base
      MAP = { :> => ">=", :>= => ">", :< => "<=", :<= => "<" }.freeze

      def edits(node)
        return [] unless node.is_a?(Prism::CallNode) && MAP.key?(node.name)
        return [] unless node.receiver && node.arguments&.arguments&.size == 1

        replacement = MAP.fetch(node.name)
        [edit(loc_range(node.message_loc), replacement,
              "replace `#{node.name}` with `#{replacement}`")]
      end
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/operators/base"
require_relative "open_mutator/operators/conditional_boundary"
```

- [x] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/operators/conditional_boundary_spec.rb`
Expected: 4 examples, 0 failures

- [x] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: operator base/registry and ConditionalBoundary operator"
```

## Task 5: ConditionForcing + LogicalOperator

**Files:**
- Create: `lib/open_mutator/operators/condition_forcing.rb`, `lib/open_mutator/operators/logical_operator.rb`
- Test: `spec/open_mutator/operators/condition_forcing_spec.rb`, `spec/open_mutator/operators/logical_operator_spec.rb`

- [x] **Step 1: Write the failing tests**

`spec/open_mutator/operators/condition_forcing_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::ConditionForcing do
  subject(:operator) { described_class.new }

  it "forces if predicates to true and false" do
    expect(mutations_of("if a > 1\n  b\nend", operator))
      .to contain_exactly("if true\n  b\nend", "if false\n  b\nend")
  end

  it "forces unless predicates" do
    expect(mutations_of("unless ready?\n  b\nend", operator))
      .to contain_exactly("unless true\n  b\nend", "unless false\n  b\nend")
  end

  it "handles modifier ifs" do
    expect(mutations_of("b if a", operator))
      .to contain_exactly("b if true", "b if false")
  end

  it "skips predicates that are already boolean literals" do
    expect(mutations_of("if true\n  b\nend", operator)).to eq(["if false\n  b\nend"])
  end

  it "does not touch while loops" do
    expect(mutations_of("while a\n  b\nend", operator)).to eq([])
  end
end
```

`spec/open_mutator/operators/logical_operator_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::LogicalOperator do
  subject(:operator) { described_class.new }

  it "swaps && with || and drops each operand" do
    expect(mutations_of("a && b", operator))
      .to contain_exactly("a || b", "a", "b")
  end

  it "swaps || with && and drops each operand" do
    expect(mutations_of("a || b", operator))
      .to contain_exactly("a && b", "a", "b")
  end

  it "handles keyword and/or (operator swap keeps symbol form)" do
    expect(mutations_of("a and b", operator)).to include("a || b", "a", "b")
  end
end
```

- [x] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/operators/condition_forcing_spec.rb spec/open_mutator/operators/logical_operator_spec.rb`
Expected: FAIL with uninitialized constant errors

- [x] **Step 3: Implement**

`lib/open_mutator/operators/condition_forcing.rb`:
```ruby
module OpenMutator
  module Operators
    class ConditionForcing < Base
      def edits(node)
        predicate =
          case node
          when Prism::IfNode, Prism::UnlessNode then node.predicate
          end
        return [] unless predicate

        %w[true false].reject { |lit| predicate.slice == lit }.map do |lit|
          edit(loc_range(predicate.location), lit, "force condition to `#{lit}`")
        end
      end
    end
  end
end
```

`lib/open_mutator/operators/logical_operator.rb`:
```ruby
module OpenMutator
  module Operators
    class LogicalOperator < Base
      def edits(node)
        case node
        when Prism::AndNode then variants(node, "||")
        when Prism::OrNode then variants(node, "&&")
        else []
        end
      end

      private

      def variants(node, swapped)
        [
          edit(loc_range(node.operator_loc), swapped,
               "replace `#{node.operator_loc.slice}` with `#{swapped}`"),
          edit(loc_range(node.location), node.left.slice, "keep only left operand"),
          edit(loc_range(node.location), node.right.slice, "keep only right operand")
        ]
      end
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/operators/condition_forcing"
require_relative "open_mutator/operators/logical_operator"
```

- [x] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/operators`
Expected: all pass

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: ConditionForcing and LogicalOperator operators"
```

## Task 6: Literal operator

**Files:**
- Create: `lib/open_mutator/operators/literal.rb`
- Test: `spec/open_mutator/operators/literal_spec.rb`

- [x] **Step 1: Write the failing tests**

`spec/open_mutator/operators/literal_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::Literal do
  subject(:operator) { described_class.new }

  it "mutates nonzero integers to 0 and n+1" do
    expect(mutations_of("x = 5", operator)).to contain_exactly("x = 0", "x = 6")
  end

  it "mutates 0 to 1 only" do
    expect(mutations_of("x = 0", operator)).to eq(["x = 1"])
  end

  it "empties nonempty strings" do
    expect(mutations_of(%(x = "hi"), operator)).to eq([%(x = "")])
  end

  it "fills empty strings" do
    expect(mutations_of(%(x = ""), operator)).to eq([%(x = "open_mutator")])
  end

  it "flips boolean literals" do
    expect(mutations_of("x = true", operator)).to eq(["x = false"])
    expect(mutations_of("x = false", operator)).to eq(["x = true"])
  end

  it "skips heredocs" do
    expect(mutations_of("x = <<~TEXT\n  body\nTEXT\n", operator)).to eq([])
  end

  it "skips bare string parts inside interpolation containers" do
    # Parts of "a#{b}c" are StringNodes without their own quotes; replacing
    # them with a quoted string would corrupt the container.
    mutants = mutations_of(%(x = "a\#{b}c"), operator)
    expect(mutants).to all(satisfy { |m| Prism.parse(m).success? })
  end
end
```

- [x] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/operators/literal_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Operators::Literal`

- [x] **Step 3: Implement**

`lib/open_mutator/operators/literal.rb`:
```ruby
module OpenMutator
  module Operators
    class Literal < Base
      def edits(node)
        case node
        when Prism::IntegerNode then integer_edits(node)
        when Prism::StringNode then string_edits(node)
        when Prism::TrueNode
          [edit(loc_range(node.location), "false", "replace `true` with `false`")]
        when Prism::FalseNode
          [edit(loc_range(node.location), "true", "replace `false` with `true`")]
        else []
        end
      end

      private

      def integer_edits(node)
        [0, node.value + 1].uniq.reject { |v| v == node.value }.map do |v|
          edit(loc_range(node.location), v.to_s, "replace `#{node.value}` with `#{v}`")
        end
      end

      def string_edits(node)
        opening = node.opening_loc&.slice
        return [] unless opening                  # quote-less parts (interpolation)
        return [] if opening.start_with?("<<")    # heredocs: v1 limit

        if node.unescaped.empty?
          [edit(loc_range(node.location), %("open_mutator"), %(replace "" with "open_mutator"))]
        else
          [edit(loc_range(node.location), %(""), %(replace string with ""))]
        end
      end
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/operators/literal"
```

- [x] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/operators/literal_spec.rb`
Expected: 7 examples, 0 failures

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Literal operator (integers, strings, booleans)"
```

## Task 7: StatementDeletion + EarlyReturn

**Files:**
- Create: `lib/open_mutator/operators/statement_deletion.rb`, `lib/open_mutator/operators/early_return.rb`
- Test: `spec/open_mutator/operators/statement_deletion_spec.rb`, `spec/open_mutator/operators/early_return_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/operators/statement_deletion_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::StatementDeletion do
  subject(:operator) { described_class.new }

  it "deletes each statement in a multi-statement body" do
    mutants = mutations_of("a\nb\nc", operator)
    expect(mutants).to contain_exactly("\nb\nc", "a\n\nc", "a\nb\n")
  end

  it "leaves single-statement bodies alone" do
    expect(mutations_of("a", operator)).to eq([])
  end
end
```

`spec/open_mutator/operators/early_return_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::EarlyReturn do
  subject(:operator) { described_class.new }

  it "unwraps return and substitutes return nil" do
    expect(mutations_of("return x", operator))
      .to contain_exactly("x", "return nil")
  end

  it "handles modifier form" do
    expect(mutations_of("return 0 if guard?", operator))
      .to contain_exactly("0 if guard?", "return nil if guard?")
  end

  it "skips bare return" do
    expect(mutations_of("return", operator)).to eq([])
  end

  it "skips return nil (no-op)" do
    expect(mutations_of("return nil", operator)).to eq(["nil"])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/operators/statement_deletion_spec.rb spec/open_mutator/operators/early_return_spec.rb`
Expected: FAIL with uninitialized constant errors

- [ ] **Step 3: Implement**

`lib/open_mutator/operators/statement_deletion.rb`:
```ruby
module OpenMutator
  module Operators
    class StatementDeletion < Base
      def edits(node)
        return [] unless node.is_a?(Prism::StatementsNode)
        return [] if node.body.size < 2

        node.body.map do |stmt|
          edit(loc_range(stmt.location), "",
               "delete `#{stmt.slice.lines.first.strip}`")
        end
      end
    end
  end
end
```

`lib/open_mutator/operators/early_return.rb`:
```ruby
module OpenMutator
  module Operators
    class EarlyReturn < Base
      def edits(node)
        return [] unless node.is_a?(Prism::ReturnNode) && node.arguments

        value = node.arguments.slice
        out = [edit(loc_range(node.location), value, "unwrap `return`")]
        unless value == "nil"
          out << edit(loc_range(node.location), "return nil", "return nil instead")
        end
        out
      end
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/operators/statement_deletion"
require_relative "open_mutator/operators/early_return"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/operators`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: StatementDeletion and EarlyReturn operators"
```

## Task 8: CallSwap (with Rails pack) + NegationRemoval

**Files:**
- Create: `lib/open_mutator/operators/call_swap.rb`, `lib/open_mutator/operators/negation_removal.rb`
- Test: `spec/open_mutator/operators/call_swap_spec.rb`, `spec/open_mutator/operators/negation_removal_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/operators/call_swap_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::CallSwap do
  subject(:operator) { described_class.new }

  {
    "xs.map { |x| x }" => "xs.each { |x| x }",
    "xs.select(&:a?)" => "xs.reject(&:a?)",
    "xs.reject(&:a?)" => "xs.select(&:a?)",
    "xs.min" => "xs.max",
    "xs.max" => "xs.min",
    "xs.first" => "xs.last",
    "xs.last" => "xs.first",
    "xs.any?" => "xs.none?",
    "xs.none?" => "xs.any?",
    "x.present?" => "x.blank?",
    "x.blank?" => "x.present?",
    "x.save" => "x.save!",
    "x.save!" => "x.save"
  }.each do |from, to|
    it "mutates #{from} to #{to}" do
      expect(mutations_of(from, operator)).to eq([to])
    end
  end

  it "ignores unmapped calls" do
    expect(mutations_of("xs.compact", operator)).to eq([])
  end
end
```

`spec/open_mutator/operators/negation_removal_spec.rb`:
```ruby
RSpec.describe OpenMutator::Operators::NegationRemoval do
  subject(:operator) { described_class.new }

  it "removes unary bang" do
    expect(mutations_of("!ready?", operator)).to eq(["ready?"])
  end

  it "removes bang from parenthesized expressions" do
    expect(mutations_of("!(a && b)", operator)).to eq(["(a && b)"])
  end

  it "ignores binary operators" do
    expect(mutations_of("a != b", operator)).to eq([])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/operators/call_swap_spec.rb spec/open_mutator/operators/negation_removal_spec.rb`
Expected: FAIL with uninitialized constant errors

- [ ] **Step 3: Implement**

`lib/open_mutator/operators/call_swap.rb`:
```ruby
module OpenMutator
  module Operators
    class CallSwap < Base
      # One-directional where the reverse is usually an equivalent mutant
      # (e.g. each→map when return value is unused).
      MAP = {
        map: "each",
        select: "reject", reject: "select",
        min: "max", max: "min",
        first: "last", last: "first",
        any?: "none?", none?: "any?",
        # Rails-aware pack:
        present?: "blank?", blank?: "present?",
        save: "save!", save!: "save"
      }.freeze

      def edits(node)
        return [] unless node.is_a?(Prism::CallNode) && node.receiver && node.message_loc

        replacement = MAP[node.name]
        return [] unless replacement

        [edit(loc_range(node.message_loc), replacement,
              "replace `.#{node.name}` with `.#{replacement}`")]
      end
    end
  end
end
```

`lib/open_mutator/operators/negation_removal.rb`:
```ruby
module OpenMutator
  module Operators
    class NegationRemoval < Base
      def edits(node)
        return [] unless node.is_a?(Prism::CallNode) && node.name == :! && node.receiver

        [edit(loc_range(node.location), node.receiver.slice, "remove negation")]
      end
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/operators/call_swap"
require_relative "open_mutator/operators/negation_removal"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/operators`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: CallSwap (with Rails pack) and NegationRemoval operators"
```

## Task 9: Mutation, Analysis, and Engine (validity gate)

**Files:**
- Create: `lib/open_mutator/mutation.rb`, `lib/open_mutator/analysis.rb`, `lib/open_mutator/engine.rb`
- Test: `spec/open_mutator/engine_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/engine_spec.rb`:
```ruby
require "tmpdir"

RSpec.describe OpenMutator::Engine do
  subject(:engine) { described_class.new }

  def analyze(source)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = OpenMutator::SubjectFinder.call(file).first
      engine.analyze(subject_)
    end
  end

  let(:source) do
    <<~RUBY
      class Gate
        def open?(pressure)
          pressure > 100
        end
      end
    RUBY
  end

  it "produces mutations from all applicable operators" do
    analysis = analyze(source)
    descriptions = analysis.mutations.map { |m| m.edit.description }
    expect(descriptions).to include("replace `>` with `>=`")
    expect(descriptions).to include("replace `100` with `0`")
  end

  it "captures mutated file, def source, and metadata" do
    mutation = analyze(source).mutations
      .find { |m| m.edit.description == "replace `>` with `>=`" }
    expect(mutation.mutated_file_source).to include("pressure >= 100")
    expect(mutation.mutated_def_source).to eq("def open?(pressure)\n    pressure >= 100\n  end")
    expect(mutation.mutated_def_line).to eq(2)
    expect(mutation.original_snippet).to eq(">")
    expect(mutation.line).to eq(3)
  end

  it "only mutates inside the subject's def" do
    two_methods = <<~RUBY
      class Gate
        def open?(pressure)
          pressure > 100
        end

        def other
          1 < 2
        end
      end
    RUBY
    analysis = analyze(two_methods) # first subject = open?
    expect(analysis.mutations.map(&:mutated_file_source)).to all(include("1 < 2"))
  end

  it "does not descend into nested defs" do
    nested = <<~RUBY
      class Gate
        def outer
          def inner = 1 > 0
          :ok
        end
      end
    RUBY
    analysis = analyze(nested)
    expect(analysis.mutations.map { |m| m.edit.description })
      .not_to include("replace `>` with `>=`")
  end

  it "counts and discards mutants that fail to re-parse" do
    # Deliberately NOT a subclass of Operators::Base — subclassing fires
    # `inherited` and would permanently register this syntax-breaking operator
    # in REGISTRY, poisoning Operators::Base.all for the rest of the process
    # (flaky property gate under random ordering). Engine only calls #edits,
    # so a duck type suffices.
    bad_operator = Class.new do
      def edits(node)
        return [] unless node.is_a?(Prism::IntegerNode)
        [OpenMutator::Edit.new(range: node.location.start_offset...node.location.end_offset,
                               replacement: "(((", description: "break syntax")]
      end
    end
    engine = described_class.new(operators: [bad_operator.new])
    Dir.mktmpdir do |dir|
      file = File.join(dir, "code.rb")
      File.write(file, source)
      subject_ = OpenMutator::SubjectFinder.call(file).first
      analysis = engine.analyze(subject_)
      expect(analysis.mutations).to be_empty
      expect(analysis.invalid_count).to eq(1)
    end
  end
end
```

Note: never subclass `Operators::Base` in tests — `inherited` registers the class permanently, and `Base.all` is exactly what the Task 20 property gate and `Engine.new` defaults iterate.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/engine_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Engine`

- [ ] **Step 3: Implement**

`lib/open_mutator/mutation.rb`:
```ruby
module OpenMutator
  # One concrete mutant. `line` is the 1-based line of the edit in the
  # ORIGINAL file (used for coverage lookup and reporting).
  Mutation = Data.define(:subject, :edit, :original_snippet, :line,
                         :mutated_file_source, :mutated_def_source, :mutated_def_line) do
    def description = edit.description

    # Original-file lines the edit touches (edit may span lines).
    def lines = line..(line + original_snippet.count("\n"))
  end
end
```

`lib/open_mutator/analysis.rb`:
```ruby
module OpenMutator
  Analysis = Data.define(:mutations, :invalid_count)
end
```

`lib/open_mutator/engine.rb`:
```ruby
module OpenMutator
  class Engine
    def initialize(operators: Operators::Base.all)
      @operators = operators
    end

    def analyze(subject, source: File.read(subject.file))
      result = Prism.parse(source)
      raise Error, "#{subject.file} no longer parses" unless result.success?

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

    private

    def find_def(node, start_offset)
      return node if node.is_a?(Prism::DefNode) && node.location.start_offset == start_offset

      node.compact_child_nodes.each do |child|
        found = find_def(child, start_offset)
        return found if found
      end
      nil
    end

    def collect_edits(def_node)
      edits = []
      walk(def_node.body) do |node|
        @operators.each { |op| edits.concat(op.edits(node)) }
      end
      edits
    end

    def walk(node, &blk)
      return if node.nil?
      return if node.is_a?(Prism::DefNode) # nested defs are separate subjects

      yield node
      node.compact_child_nodes.each { |child| walk(child, &blk) }
    end

    # Returns [mutation_or_nil, valid_boolean].
    # valid=true with nil mutation means "skipped no-op", which is not an error.
    def build_mutation(subject, source, edit)
      original = source.byteslice(edit.range)
      return [nil, true] if edit.replacement == original # no-op guard

      mutated = Splicer.apply(source, [edit])
      parsed = Prism.parse(mutated)
      return [nil, false] unless parsed.success?

      new_def = find_def(parsed.value, subject.byte_range.begin)
      return [nil, false] unless new_def

      [Mutation.new(
        subject: subject,
        edit: edit,
        original_snippet: original,
        line: source.byteslice(0, edit.range.begin).count("\n") + 1,
        mutated_file_source: mutated,
        mutated_def_source: new_def.slice,
        mutated_def_line: new_def.location.start_line
      ), true]
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/mutation"
require_relative "open_mutator/analysis"
require_relative "open_mutator/engine"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/engine_spec.rb`
Expected: 5 examples, 0 failures

- [ ] **Step 5: Run the whole suite**

Run: `bundle exec rspec`
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: Mutation engine with re-parse validity gate"
```

---

# Phase 3 — Coverage Map

## Task 10: Baseline hooks (instrumented RSpec run)

**Files:**
- Create: `lib/open_mutator/baseline_hooks.rb`
- Test: `spec/open_mutator/baseline_hooks_spec.rb`

**Important:** this file is loaded standalone in the HOST project's suite via `RUBYOPT=-ropen_mutator/baseline_hooks` — NOT via `rspec --require`. RSpec merges project-file `.rspec` requires before command-line requires, so `rspec --require` would fire AFTER the host's `--require spec_helper` has already loaded the app, and `Coverage` only instruments files loaded after `Coverage.start` — the map would be empty. `RUBYOPT`'s `-r` fires before rspec boots (under `bundle exec`, Bundler puts the gem's lib dir on the load path first). Consequence: at load time rspec-core may not be loaded yet, so this file must `require "rspec/core"` itself before `RSpec.configure`.

It must never be required by `lib/open_mutator.rb` — it starts `Coverage` at load time. Its pure functions live in `OpenMutator::BaselineHooks` so they are unit-testable without triggering instrumentation (`Coverage.start` and the RSpec hooks are guarded behind `ENV["OPEN_MUTATOR_BASELINE_OUT"]`).

Timing note: `example.execution_result.run_time` is nil inside `around(:each)` hooks (RSpec sets it after around hooks complete), so the hook measures elapsed time itself with a monotonic clock.

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/baseline_hooks_spec.rb`:
```ruby
require "open_mutator/baseline_hooks"

RSpec.describe OpenMutator::BaselineHooks do
  describe ".diff_coverage" do
    it "returns [path, line] pairs whose hit count increased" do
      before = { "/root/lib/a.rb" => { lines: [1, 0, nil, 2] } }
      after  = { "/root/lib/a.rb" => { lines: [1, 1, nil, 5] } }
      expect(described_class.diff_coverage(before, after, "/root"))
        .to contain_exactly(["/root/lib/a.rb", 2], ["/root/lib/a.rb", 4])
    end

    it "includes files first seen after the example started" do
      after = { "/root/lib/b.rb" => { lines: [nil, 1] } }
      expect(described_class.diff_coverage({}, after, "/root"))
        .to eq([["/root/lib/b.rb", 2]])
    end

    it "ignores files outside the project root and spec files" do
      after = {
        "/gems/x.rb" => { lines: [1] },
        "/root/spec/a_spec.rb" => { lines: [1] },
        "/root/lib/a.rb" => { lines: [1] }
      }
      expect(described_class.diff_coverage({}, after, "/root"))
        .to eq([["/root/lib/a.rb", 1]])
    end
  end

  describe ".build_payload" do
    it "inverts per-example hits into a line index" do
      records = {
        "spec/a_spec.rb[1:1]" => [["/root/lib/a.rb", 3], ["/root/lib/a.rb", 4]],
        "spec/a_spec.rb[1:2]" => [["/root/lib/a.rb", 3]]
      }
      times = { "spec/a_spec.rb[1:1]" => 0.5, "spec/a_spec.rb[1:2]" => 0.1 }
      payload = described_class.build_payload(records, times)
      expect(payload["map"]["/root/lib/a.rb:3"])
        .to contain_exactly("spec/a_spec.rb[1:1]", "spec/a_spec.rb[1:2]")
      expect(payload["map"]["/root/lib/a.rb:4"]).to eq(["spec/a_spec.rb[1:1]"])
      expect(payload["times"]).to eq(times)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/baseline_hooks_spec.rb`
Expected: FAIL (cannot load such file or uninitialized constant)

- [ ] **Step 3: Implement**

`lib/open_mutator/baseline_hooks.rb`:
```ruby
# Loaded standalone via RUBYOPT=-ropen_mutator/baseline_hooks in the host
# project's suite — before rspec boots, so Coverage instruments everything
# the suite loads (including code loaded by spec_helper). Records per-example
# coverage diffs and writes the inverted map to OPEN_MUTATOR_BASELINE_OUT.
require "json"

module OpenMutator
  module BaselineHooks
    RECORDS = {}
    TIMES = {}

    def self.diff_coverage(before, after, root)
      hits = []
      after.each do |path, data|
        next unless path.start_with?(root)
        next if path.include?("/spec/")

        before_lines = before.dig(path, :lines)
        data[:lines].each_with_index do |count, idx|
          next if count.nil?

          previous = before_lines ? before_lines[idx].to_i : 0
          hits << [path, idx + 1] if count > previous
        end
      end
      hits
    end

    def self.build_payload(records, times)
      map = Hash.new { |h, k| h[k] = [] }
      records.each do |example_id, hits|
        hits.each { |path, line| map["#{path}:#{line}"] << example_id }
      end
      { "map" => map, "times" => times }
    end
  end
end

if ENV["OPEN_MUTATOR_BASELINE_OUT"]
  require "coverage"
  Coverage.start(lines: true)
  require "rspec/core" # loaded via RUBYOPT, so rspec isn't up yet

  RSpec.configure do |config|
    config.around(:each) do |example|
      before = Coverage.peek_result
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      example.run
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      after = Coverage.peek_result
      root = ENV.fetch("OPEN_MUTATOR_ROOT")
      OpenMutator::BaselineHooks::RECORDS[example.id] =
        OpenMutator::BaselineHooks.diff_coverage(before, after, root)
      # NOT example.execution_result.run_time — that is nil until after
      # around hooks complete.
      OpenMutator::BaselineHooks::TIMES[example.id] = elapsed
    end

    config.after(:suite) do
      payload = OpenMutator::BaselineHooks.build_payload(
        OpenMutator::BaselineHooks::RECORDS, OpenMutator::BaselineHooks::TIMES
      )
      File.write(ENV.fetch("OPEN_MUTATOR_BASELINE_OUT"), JSON.generate(payload))
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/baseline_hooks_spec.rb`
Expected: 4 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: baseline hooks for per-example coverage capture"
```

## Task 11: CoverageMap

**Files:**
- Create: `lib/open_mutator/coverage_map.rb`
- Test: `spec/open_mutator/coverage_map_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/coverage_map_spec.rb`:
```ruby
RSpec.describe OpenMutator::CoverageMap do
  subject(:map) do
    described_class.new(
      "map" => {
        "/root/lib/a.rb:3" => ["spec/a_spec.rb[1:1]", "spec/b_spec.rb[1:1]"],
        "/root/lib/a.rb:4" => ["spec/a_spec.rb[1:1]"]
      },
      "times" => { "spec/a_spec.rb[1:1]" => 0.5, "spec/b_spec.rb[1:1]" => 0.25 },
      "digests" => { "lib/a.rb" => "abc" }
    )
  end

  it "returns the union of examples across lines" do
    expect(map.examples_for("/root/lib/a.rb", 3..4))
      .to contain_exactly("spec/a_spec.rb[1:1]", "spec/b_spec.rb[1:1]")
  end

  it "returns [] for uncovered lines" do
    expect(map.examples_for("/root/lib/a.rb", 99..99)).to eq([])
  end

  it "sums known example times" do
    expect(map.time_for(["spec/a_spec.rb[1:1]", "spec/b_spec.rb[1:1]", "unknown"]))
      .to eq(0.75)
  end

  it "treats recorded-but-nil times as zero" do
    nil_map = described_class.new(
      "map" => {}, "times" => { "spec/n_spec.rb[1:1]" => nil }, "digests" => {}
    )
    expect(nil_map.time_for(["spec/n_spec.rb[1:1]"])).to eq(0.0)
  end

  it "checks freshness against digests" do
    expect(map.fresh?("lib/a.rb" => "abc")).to be(true)
    expect(map.fresh?("lib/a.rb" => "zzz")).to be(false)
  end

  it "loads from a JSON file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "coverage.json")
      File.write(path, JSON.generate("map" => {}, "times" => {}, "digests" => {}))
      expect(described_class.load(path).examples_for("/x.rb", 1..1)).to eq([])
    end
  end
end
```

Add `require "tmpdir"` and `require "json"` at the top of this spec file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/coverage_map_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::CoverageMap`

- [ ] **Step 3: Implement**

`lib/open_mutator/coverage_map.rb`:
```ruby
require "json"

module OpenMutator
  class CoverageMap
    def self.load(path) = new(JSON.parse(File.read(path)))

    def initialize(data)
      @map = data.fetch("map")
      @times = data.fetch("times", {})
      @digests = data.fetch("digests", {})
    end

    def examples_for(file, lines)
      lines.flat_map { |line| @map.fetch("#{file}:#{line}", []) }.uniq.sort
    end

    def time_for(example_ids)
      # `|| 0.0`, not fetch-with-default: a key present with nil value must
      # also coerce to zero, or Runner#plan_work explodes with TypeError.
      example_ids.sum { |id| @times[id] || 0.0 }
    end

    def fresh?(digests) = @digests == digests
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/coverage_map"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/coverage_map_spec.rb`
Expected: 6 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: CoverageMap inverted-index wrapper"
```

## Task 12: Baseline runner + tiny_project fixture

**Files:**
- Create: `lib/open_mutator/baseline.rb`
- Create: `spec/fixtures/tiny_project/` (Gemfile, .rspec, lib/calculator.rb, spec/spec_helper.rb, spec/calculator_spec.rb)
- Test: `spec/open_mutator/baseline_spec.rb` (tagged `:integration`)

- [ ] **Step 1: Create the fixture project**

This fixture is shared by the baseline integration test (here) and the E2E test (Task 19). Its planted mutants are deliberate:
- `Calculator#eligible?` — fully tested; all its mutants must be **killed**.
- `Calculator#discount` — missing a boundary test at exactly 100; two mutants must **survive**: `<` → `<=` and `100` → `101` (both are equivalent on the tested inputs 50 and 200).
- `Calculator#untested_helper` — no covering examples; its mutants must report **uncovered**.

`spec/fixtures/tiny_project/Gemfile`:
```ruby
source "https://rubygems.org"

gem "open_mutator", path: "../../.."
gem "rspec", "~> 3.13"
```

`spec/fixtures/tiny_project/.rspec`:
```
--require spec_helper
```

`spec/fixtures/tiny_project/lib/calculator.rb`:
```ruby
class Calculator
  def eligible?(age)
    if age >= 18
      "yes"
    else
      "no"
    end
  end

  def discount(total)
    return 0 if total < 100
    total / 10
  end

  def untested_helper
    42
  end
end
```

`spec/fixtures/tiny_project/spec/spec_helper.rb`:
```ruby
require_relative "../lib/calculator"
```

`spec/fixtures/tiny_project/spec/calculator_spec.rb`:
```ruby
RSpec.describe Calculator do
  subject(:calc) { Calculator.new }

  describe "#eligible?" do
    it { expect(calc.eligible?(18)).to eq("yes") }
    it { expect(calc.eligible?(19)).to eq("yes") }
    it { expect(calc.eligible?(10)).to eq("no") }
  end

  describe "#discount" do
    it { expect(calc.discount(50)).to eq(0) }
    it { expect(calc.discount(200)).to eq(20) }
    # NOTE: no test at exactly 100 — the `<` → `<=` and `100` → `101`
    # mutants survive. Planted on purpose.
  end
end
```

Run: `cd spec/fixtures/tiny_project && BUNDLE_GEMFILE=Gemfile bundle install && BUNDLE_GEMFILE=Gemfile bundle exec rspec && cd -`
Expected: 5 examples, 0 failures

- [ ] **Step 2: Write the failing integration test**

`spec/open_mutator/baseline_spec.rb`:
```ruby
require "fileutils"

RSpec.describe OpenMutator::Baseline, :integration do
  let(:root) { File.expand_path("../fixtures/tiny_project", __dir__) }
  let(:cache_dir) { File.join(root, ".open_mutator") }

  after { FileUtils.rm_rf(cache_dir) }

  def run_in_fixture
    Bundler.with_unbundled_env do
      ENV["BUNDLE_GEMFILE"] = File.join(root, "Gemfile")
      yield
    ensure
      ENV.delete("BUNDLE_GEMFILE")
    end
  end

  it "runs an instrumented baseline and returns a usable map" do
    map = run_in_fixture { described_class.new(root: root).coverage_map }
    calculator = File.join(root, "lib/calculator.rb")
    # eligible? body (lines 3-7) is covered:
    expect(map.examples_for(calculator, 3..3)).not_to be_empty
    # untested_helper body (`42`, line 16) is not:
    expect(map.examples_for(calculator, 16..16)).to eq([])
  end

  it "reuses a fresh cache without re-running" do
    baseline = described_class.new(root: root)
    run_in_fixture { baseline.coverage_map }
    mtime = File.mtime(File.join(cache_dir, "coverage.json"))
    run_in_fixture { baseline.coverage_map }
    expect(File.mtime(File.join(cache_dir, "coverage.json"))).to eq(mtime)
  end

  it "raises BaselineFailed when the suite is red" do
    broken_spec = File.join(root, "spec", "broken_spec.rb")
    File.write(broken_spec, "RSpec.describe('x') { it { expect(1).to eq(2) } }\n")
    begin
      expect { run_in_fixture { described_class.new(root: root).coverage_map } }
        .to raise_error(OpenMutator::BaselineFailed)
    ensure
      File.delete(broken_spec)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `OPEN_MUTATOR_INTEGRATION=1 bundle exec rspec spec/open_mutator/baseline_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Baseline`

- [ ] **Step 4: Implement**

`lib/open_mutator/baseline.rb`:
```ruby
require "digest"
require "fileutils"
require "json"

module OpenMutator
  # Runs the host suite once, instrumented, in a subprocess. Produces and
  # caches the CoverageMap. Invalidation is coarse: any digest change in
  # {app,lib,spec}/**/*.rb triggers a full re-run.
  class Baseline
    def initialize(root:, cache_dir: File.join(root, ".open_mutator"))
      @root = root
      @cache_dir = cache_dir
      @out_path = File.join(cache_dir, "coverage.json")
    end

    def coverage_map(force: false)
      digests = current_digests
      if !force && File.exist?(@out_path)
        map = CoverageMap.load(@out_path)
        return map if map.fresh?(digests)
      end
      run_baseline!
      stamp_digests(digests)
      CoverageMap.load(@out_path)
    end

    private

    def run_baseline!
      FileUtils.mkdir_p(@cache_dir)
      env = {
        "OPEN_MUTATOR_ROOT" => @root,
        "OPEN_MUTATOR_BASELINE_OUT" => @out_path,
        # RUBYOPT, not `rspec --require`: project .rspec requires (spec_helper
        # → app code) run before command-line requires, and Coverage misses
        # everything loaded before Coverage.start. -r fires before rspec boots.
        "RUBYOPT" => "-ropen_mutator/baseline_hooks"
      }
      # out: :err — the subprocess suite's progress output must not pollute
      # our stdout (breaks `--format json` consumers).
      ok = system(env, "bundle", "exec", "rspec", chdir: @root, out: :err)
      raise BaselineFailed, "baseline suite failed — fix the suite before mutating" unless ok
      raise BaselineFailed, "baseline produced no coverage output" unless File.exist?(@out_path)
    end

    def stamp_digests(digests)
      data = JSON.parse(File.read(@out_path))
      data["digests"] = digests
      File.write(@out_path, JSON.generate(data))
    end

    def current_digests
      Dir[File.join(@root, "{app,lib,spec}/**/*.rb")].sort.to_h do |f|
        [f.delete_prefix("#{@root}/"), Digest::SHA256.file(f).hexdigest]
      end
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/baseline"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `OPEN_MUTATOR_INTEGRATION=1 bundle exec rspec spec/open_mutator/baseline_spec.rb`
Expected: 3 examples, 0 failures

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: baseline runner with digest-keyed cache; tiny_project fixture"
```

---

# Phase 4 — Kill Pipeline

## Task 13: Inserter

**Files:**
- Create: `lib/open_mutator/inserter.rb`
- Test: `spec/open_mutator/inserter_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/inserter_spec.rb`:
```ruby
RSpec.describe OpenMutator::Inserter do
  subject(:inserter) { described_class.new }

  def mutation_stub(scope:, def_source:, kind: :instance)
    subject_ = OpenMutator::Subject.new(
      name: "test", file: "(test)", byte_range: 0...1, line_range: 1..1,
      constant_scope: scope, kind: kind
    )
    instance_double(OpenMutator::Mutation,
                    subject: subject_, mutated_def_source: def_source, mutated_def_line: 1)
  end

  before do
    stub_const("InserterFixture", Class.new do
      def value = 1
      def self.build = :original
    end)
  end

  it "redefines an instance method in the constant scope" do
    inserter.insert(mutation_stub(scope: "InserterFixture", def_source: "def value = 99"))
    expect(InserterFixture.new.value).to eq(99)
  end

  it "redefines a singleton method" do
    inserter.insert(mutation_stub(scope: "InserterFixture",
                                  def_source: "def self.build = :mutated", kind: :singleton))
    expect(InserterFixture.build).to eq(:mutated)
  end

  it "raises for unknown scopes" do
    expect { inserter.insert(mutation_stub(scope: "NoSuchScope", def_source: "def x = 1")) }
      .to raise_error(NameError)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/inserter_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Inserter`

- [ ] **Step 3: Implement**

`lib/open_mutator/inserter.rb`:
```ruby
module OpenMutator
  # Redefines the subject's method with its mutated source. `class_eval` of a
  # `def` handles instance methods; a `def self.x` source string defines the
  # singleton method the same way. Top-level subjects eval at main scope.
  class Inserter
    def insert(mutation)
      subject = mutation.subject
      if subject.constant_scope
        Object.const_get(subject.constant_scope)
              .class_eval(mutation.mutated_def_source, subject.file, mutation.mutated_def_line)
      else
        eval(mutation.mutated_def_source, TOPLEVEL_BINDING, # rubocop:disable Security/Eval
             subject.file, mutation.mutated_def_line)
      end
      nil
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/inserter"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/inserter_spec.rb`
Expected: 3 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Inserter evals mutated defs into constant scope"
```

## Task 14: Worker

**Files:**
- Create: `lib/open_mutator/worker.rb`
- Test: `spec/open_mutator/worker_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/worker_spec.rb`:
```ruby
require "json"
require "stringio"

RSpec.describe OpenMutator::Worker do
  let(:writer) { StringIO.new }
  let(:mutation) { instance_double(OpenMutator::Mutation) }
  let(:rspec_runner) { instance_double(RSpec::Core::Runner) }

  def emitted
    JSON.parse(writer.string)
  end

  def run_worker
    described_class.new(mutation, ["spec/x_spec.rb[1:1]"], writer).run
  end

  before do
    allow(RSpec::Core::Runner).to receive(:new).and_return(rspec_runner)
    allow(rspec_runner).to receive(:setup)
    allow(RSpec.world).to receive(:ordered_example_groups).and_return([])
    allow_any_instance_of(OpenMutator::Inserter).to receive(:insert)
  end

  it "emits killed when examples fail" do
    allow(rspec_runner).to receive(:run_specs).and_return(1)
    run_worker
    expect(emitted).to eq("status" => "killed", "details" => nil)
  end

  it "emits survived when examples pass" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    run_worker
    expect(emitted).to eq("status" => "survived", "details" => nil)
  end

  it "loads specs BEFORE inserting the mutation" do
    calls = []
    allow(rspec_runner).to receive(:setup) { calls << :setup }
    allow_any_instance_of(OpenMutator::Inserter).to receive(:insert) { calls << :insert }
    allow(rspec_runner).to receive(:run_specs) do
      calls << :run_specs
      0
    end
    run_worker
    expect(calls).to eq(%i[setup insert run_specs])
  end

  it "emits error when insertion raises" do
    allow(rspec_runner).to receive(:run_specs).and_return(0)
    allow_any_instance_of(OpenMutator::Inserter)
      .to receive(:insert).and_raise(SyntaxError, "boom")
    run_worker
    expect(emitted["status"]).to eq("error")
    expect(emitted["details"]).to include("SyntaxError", "boom")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/worker_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Worker`

- [ ] **Step 3: Implement**

`lib/open_mutator/worker.rb`:
```ruby
require "json"

module OpenMutator
  # Runs INSIDE a fork. Order is critical: RSpec's setup phase loads the spec
  # files, whose spec_helper/rails_helper loads the application — only THEN
  # can the mutation be inserted over the loaded original. Insert-first would
  # NameError on any project not preloaded in the parent (all non-Rails
  # projects), and loading app code after insertion would silently restore
  # the original method.
  class Worker
    def self.run(mutation, example_ids, writer)
      new(mutation, example_ids, writer).run
    end

    def initialize(mutation, example_ids, writer)
      @mutation = mutation
      @example_ids = example_ids
      @writer = writer
    end

    def run
      require "rspec/core"
      devnull = File.open(File::NULL, "w")
      runner = RSpec::Core::Runner.new(RSpec::Core::ConfigurationOptions.new(@example_ids))
      runner.setup(devnull, devnull)   # loads spec files -> loads the app
      Inserter.new.insert(@mutation)   # now the target constant exists
      after_fork_hygiene
      code = runner.run_specs(RSpec.world.ordered_example_groups)
      emit(code.zero? ? "survived" : "killed")
    rescue StandardError, ScriptError => e
      emit("error", details: "#{e.class}: #{e.message}")
    end

    private

    def after_fork_hygiene
      srand
      if defined?(ActiveRecord::Base)
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ActiveRecord::Base.establish_connection
      end
    end

    def emit(status, details: nil)
      @writer.puts(JSON.generate("status" => status, "details" => details))
      @writer.flush if @writer.respond_to?(:flush)
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/worker"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/worker_spec.rb`
Expected: 4 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Worker — load specs, insert mutation, in-process kill run"
```

## Task 15: Result, WorkItem, Scheduler (fork pool + deadlines)

**Files:**
- Create: `lib/open_mutator/result.rb`, `lib/open_mutator/work_item.rb`, `lib/open_mutator/scheduler.rb`
- Test: `spec/open_mutator/scheduler_spec.rb`

- [ ] **Step 1: Write the failing tests**

The scheduler forks real processes; tests inject a fake worker lambda so no RSpec-in-RSpec runs. These tests fork and sleep — they stay in the default suite (sub-second) but must not run on platforms without fork.

`spec/open_mutator/scheduler_spec.rb`:
```ruby
require "json"

RSpec.describe OpenMutator::Scheduler do
  def item(timeout: 5.0)
    OpenMutator::WorkItem.new(mutation: nil, example_ids: [], timeout: timeout)
  end

  def scheduler(worker:, jobs: 2, on_result: nil)
    described_class.new(jobs: jobs, worker: worker, on_result: on_result)
  end

  it "collects statuses reported by workers" do
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "killed", "details" => nil)) }
    results = scheduler(worker: worker).run([item, item, item])
    expect(results.map(&:status)).to eq(%i[killed killed killed])
  end

  it "marks silent crashes as :error" do
    worker = ->(_m, _e, _w) { Process.exit!(1) }
    results = scheduler(worker: worker).run([item])
    expect(results.map(&:status)).to eq([:error])
  end

  it "kills over-deadline workers and marks :timeout" do
    worker = ->(_m, _e, _w) { sleep 30 }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = scheduler(worker: worker).run([item(timeout: 0.2)])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(results.map(&:status)).to eq([:timeout])
    expect(elapsed).to be < 5
  end

  it "invokes on_result as each result lands" do
    seen = []
    worker = ->(_m, _e, writer) { writer.puts(JSON.generate("status" => "survived", "details" => nil)) }
    scheduler(worker: worker, on_result: ->(r) { seen << r.status }).run([item, item])
    expect(seen).to eq(%i[survived survived])
  end

  it "respects the jobs cap" do
    worker = lambda do |_m, _e, writer|
      sleep 0.15
      writer.puts(JSON.generate("status" => "killed", "details" => nil))
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    scheduler(worker: worker, jobs: 2).run([item, item, item, item])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be >= 0.3 # 4 items / 2 jobs => at least two waves
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/scheduler_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::Scheduler`

- [ ] **Step 3: Implement**

`lib/open_mutator/result.rb`:
```ruby
module OpenMutator
  # status: :killed | :survived | :timeout | :error | :uncovered
  Result = Data.define(:mutation, :status, :details) do
    def detected? = %i[killed timeout].include?(status)
  end
end
```

`lib/open_mutator/work_item.rb`:
```ruby
module OpenMutator
  WorkItem = Data.define(:mutation, :example_ids, :timeout)
end
```

`lib/open_mutator/scheduler.rb`:
```ruby
require "json"

module OpenMutator
  # Fork pool: one fork per WorkItem, capped at `jobs` concurrent forks.
  # Parent enforces per-item deadlines with SIGKILL (worker-side timeouts
  # cannot interrupt all infinite loops).
  class Scheduler
    def initialize(jobs:, worker: Worker.method(:run), on_result: nil)
      @jobs = jobs
      @worker = worker
      @on_result = on_result
    end

    def run(items)
      queue = items.dup
      running = {}
      results = []
      previous_traps = install_signal_handlers(running)
      until queue.empty? && running.empty?
        spawn(queue.shift, running) while running.size < @jobs && !queue.empty?
        reap(running, results)
        sleep 0.02 unless running.empty?
      end
      results
    ensure
      restore_traps(previous_traps) if previous_traps
    end

    private

    def spawn(item, running)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        Process.setpgid(0, 0)          # own process group: deadline kill reaps grandchildren too
        $stdout.reopen(File::NULL)     # app code that prints must not corrupt parent's report
        @worker.call(item.mutation, item.example_ids, writer)
        writer.close
        Process.exit!(0)
      end
      writer.close
      running[pid] = { reader: reader, item: item, deadline: now + item.timeout }
    end

    def reap(running, results)
      running.to_a.each do |pid, entry|
        done, _status = Process.waitpid2(pid, Process::WNOHANG)
        if done
          running.delete(pid)
          results << finish(entry)
        elsif now > entry[:deadline]
          kill(pid)
          running.delete(pid)
          entry[:reader].close
          results << report(Result.new(mutation: entry[:item].mutation, status: :timeout, details: nil))
        end
      end
    end

    def finish(entry)
      payload = entry[:reader].read.to_s
      entry[:reader].close
      data = payload.empty? ? nil : JSON.parse(payload)
      status = data ? data.fetch("status").to_sym : :error
      details = data ? data["details"] : "worker exited without reporting"
      report(Result.new(mutation: entry[:item].mutation, status: status, details: details))
    end

    def report(result)
      @on_result&.call(result)
      result
    end

    def kill(pid)
      Process.kill("KILL", -pid) # negative pid = whole process group
    rescue Errno::ESRCH, Errno::EPERM
      # Group not established yet (setpgid race) or already gone — direct kill.
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    ensure
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end

    # Returns {sig => previous_handler} so #run can restore on exit —
    # otherwise our traps permanently replace the host's (e.g. RSpec's Ctrl-C).
    def install_signal_handlers(running)
      %w[INT TERM].to_h do |sig|
        previous = trap(sig) do
          running.each_key do |pid|
            Process.kill("KILL", -pid)
          rescue StandardError
            nil
          end
          exit(130)
        end
        [sig, previous]
      end
    end

    def restore_traps(previous)
      previous.each { |sig, handler| trap(sig, handler || "DEFAULT") }
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/result"
require_relative "open_mutator/work_item"
require_relative "open_mutator/scheduler"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/scheduler_spec.rb`
Expected: 5 examples, 0 failures

- [ ] **Step 5: Run whole suite**

Run: `bundle exec rspec`
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: fork-pool scheduler with parent-enforced deadlines"
```

---

# Phase 5 — Reporting & CLI

## Task 16: Terminal and JSON reporters

**Files:**
- Create: `lib/open_mutator/reporter/terminal.rb`, `lib/open_mutator/reporter/json.rb`
- Test: `spec/open_mutator/reporter/terminal_spec.rb`, `spec/open_mutator/reporter/json_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/reporter/terminal_spec.rb`:
```ruby
require "stringio"

RSpec.describe OpenMutator::Reporter::Terminal do
  let(:out) { StringIO.new }
  subject(:reporter) { described_class.new(out: out) }

  def mutation(description: "replace `<` with `<=`")
    subject_ = OpenMutator::Subject.new(
      name: "Calculator#discount", file: "lib/calculator.rb",
      byte_range: 0...1, line_range: 10..13, constant_scope: "Calculator", kind: :instance
    )
    OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: 5...6, replacement: "<=", description: description),
      original_snippet: "<", line: 11,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 10
    )
  end

  def result(status)
    OpenMutator::Result.new(mutation: mutation, status: status, details: nil)
  end

  it "prints one progress char per result" do
    %i[killed survived timeout error uncovered].each { |s| reporter.on_result(result(s)) }
    expect(out.string).to eq(".STEU")
  end

  it "summarizes counts, score, and survivor diffs" do
    results = [result(:killed), result(:killed), result(:timeout), result(:survived)]
    reporter.summary(results, invalid_count: 2)
    text = out.string
    expect(text).to include("killed: 2", "timeout: 1", "survived: 1", "invalid (discarded): 2")
    expect(text).to include("Mutation score: 75.0%") # (2+1)/(2+1+1)
    expect(text).to include("Calculator#discount", "lib/calculator.rb:11")
    expect(text).to include("replace `<` with `<=`")
    expect(text).to include("- <", "+ <=")
  end

  it "reports 100.0% when nothing survives" do
    reporter.summary([result(:killed)], invalid_count: 0)
    expect(out.string).to include("Mutation score: 100.0%")
  end
end
```

`spec/open_mutator/reporter/json_spec.rb`:
```ruby
require "json"
require "stringio"

RSpec.describe OpenMutator::Reporter::Json do
  let(:out) { StringIO.new }
  subject(:reporter) { described_class.new(out: out) }

  it "emits machine-readable results" do
    subject_ = OpenMutator::Subject.new(
      name: "Calculator#discount", file: "lib/calculator.rb",
      byte_range: 0...1, line_range: 10..13, constant_scope: "Calculator", kind: :instance
    )
    mutation = OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: 5...6, replacement: "<=", description: "replace `<` with `<=`"),
      original_snippet: "<", line: 11,
      mutated_file_source: "", mutated_def_source: "", mutated_def_line: 10
    )
    result = OpenMutator::Result.new(mutation: mutation, status: :survived, details: nil)
    reporter.on_result(result) # must be a no-op, not crash
    reporter.summary([result], invalid_count: 1)

    data = JSON.parse(out.string)
    expect(data["score"]).to eq(0.0)
    expect(data["counts"]).to eq("survived" => 1)
    expect(data["invalid"]).to eq(1)
    expect(data["results"].first).to include(
      "subject" => "Calculator#discount",
      "status" => "survived",
      "description" => "replace `<` with `<=`",
      "file" => "lib/calculator.rb",
      "line" => 11
    )
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/reporter`
Expected: FAIL with uninitialized constant errors

- [ ] **Step 3: Implement**

`lib/open_mutator/reporter/terminal.rb`:
```ruby
module OpenMutator
  module Reporter
    class Terminal
      CHARS = { killed: ".", survived: "S", timeout: "T", error: "E", uncovered: "U" }.freeze

      def initialize(out: $stdout)
        @out = out
      end

      def on_result(result)
        @out.print(CHARS.fetch(result.status))
      end

      def summary(results, invalid_count:)
        counts = results.group_by(&:status).transform_values(&:size)
        @out.puts "", ""
        CHARS.each_key do |status|
          @out.puts "#{status}: #{counts.fetch(status, 0)}"
        end
        @out.puts "invalid (discarded): #{invalid_count}"
        @out.puts format("Mutation score: %.1f%%", score(counts) * 100)
        survivors = results.select { |r| r.status == :survived }
        print_survivors(survivors) unless survivors.empty?
      end

      def self.score(counts)
        detected = counts.fetch(:killed, 0) + counts.fetch(:timeout, 0)
        denominator = detected + counts.fetch(:survived, 0)
        return 1.0 if denominator.zero?

        detected.to_f / denominator
      end

      private

      def score(counts) = self.class.score(counts)

      def print_survivors(survivors)
        @out.puts "", "Surviving mutants:"
        survivors.each do |result|
          m = result.mutation
          @out.puts "", "  #{m.subject.name} (#{m.subject.file}:#{m.line})"
          @out.puts "    #{m.description}"
          @out.puts "    - #{m.original_snippet}"
          @out.puts "    + #{m.edit.replacement}"
        end
      end
    end
  end
end
```

`lib/open_mutator/reporter/json.rb`:
```ruby
require "json"

module OpenMutator
  module Reporter
    class Json
      def initialize(out: $stdout)
        @out = out
      end

      def on_result(result); end

      def summary(results, invalid_count:)
        counts = results.group_by(&:status).transform_values(&:size)
        @out.puts JSON.pretty_generate(
          "score" => Terminal.score(counts),
          "counts" => counts.transform_keys(&:to_s),
          "invalid" => invalid_count,
          "results" => results.map { |r| serialize(r) }
        )
      end

      private

      def serialize(result)
        m = result.mutation
        {
          "subject" => m.subject.name,
          "status" => result.status.to_s,
          "description" => m.description,
          "file" => m.subject.file,
          "line" => m.line,
          "original" => m.original_snippet,
          "replacement" => m.edit.replacement,
          "details" => result.details
        }
      end
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/reporter/terminal"
require_relative "open_mutator/reporter/json"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/reporter`
Expected: 4 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: terminal and JSON reporters"
```

## Task 17: SinceFilter

**Files:**
- Create: `lib/open_mutator/since_filter.rb`
- Test: `spec/open_mutator/since_filter_spec.rb`

- [ ] **Step 1: Write the failing tests**

`spec/open_mutator/since_filter_spec.rb`:
```ruby
RSpec.describe OpenMutator::SinceFilter do
  describe ".parse" do
    it "extracts added/changed line numbers per file from unified=0 diffs" do
      diff = <<~DIFF
        diff --git a/lib/a.rb b/lib/a.rb
        --- a/lib/a.rb
        +++ b/lib/a.rb
        @@ -10,0 +11,2 @@ def x
        +  new_line_11
        +  new_line_12
        @@ -20 +22 @@ def y
        -  old
        +  changed_22
        diff --git a/lib/b.rb b/lib/b.rb
        --- a/lib/b.rb
        +++ b/lib/b.rb
        @@ -1 +1 @@
        -a
        +b
      DIFF
      expect(described_class.parse(diff)).to eq(
        "lib/a.rb" => [11, 12, 22],
        "lib/b.rb" => [1]
      )
    end

    it "ignores pure deletions (zero new-side count)" do
      diff = <<~DIFF
        +++ b/lib/a.rb
        @@ -5,2 +4,0 @@
        -gone
        -gone
      DIFF
      expect(described_class.parse(diff)).to eq({})
    end
  end

  describe "#cover?" do
    it "matches subjects whose line_range intersects changed lines" do
      filter = described_class.allocate
      filter.instance_variable_set(:@root, "/root")
      filter.instance_variable_set(:@changed, "lib/a.rb" => [11, 12])

      hit = OpenMutator::Subject.new(name: "A#x", file: "/root/lib/a.rb",
                                     byte_range: 0...1, line_range: 10..14,
                                     constant_scope: "A", kind: :instance)
      miss = hit.with(line_range: 20..24)
      other_file = hit.with(file: "/root/lib/z.rb")

      expect(filter.cover?(hit)).to be(true)
      expect(filter.cover?(miss)).to be(false)
      expect(filter.cover?(other_file)).to be(false)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/since_filter_spec.rb`
Expected: FAIL with `uninitialized constant OpenMutator::SinceFilter`

- [ ] **Step 3: Implement**

`lib/open_mutator/since_filter.rb`:
```ruby
module OpenMutator
  # Restricts subjects to methods overlapping lines changed since a git ref.
  # Known v1 limit: `git diff <ref>` omits untracked files, so brand-new
  # uncommitted files are skipped.
  class SinceFilter
    HUNK = /\A@@ [^+]*\+(\d+)(?:,(\d+))? @@/

    def self.parse(diff_text)
      changed = Hash.new { |h, k| h[k] = [] }
      current = nil
      diff_text.each_line do |line|
        if line.start_with?("+++ b/")
          current = line.delete_prefix("+++ b/").strip
        elsif current && (match = HUNK.match(line))
          start = match[1].to_i
          count = (match[2] || "1").to_i
          count.times { |i| changed[current] << start + i }
        end
      end
      changed.reject { |_, lines| lines.empty? }
    end

    def initialize(ref:, root:)
      @root = root
      diff = IO.popen(
        ["git", "-C", root, "diff", "--unified=0", ref, "--", "*.rb"], &:read
      )
      raise Error, "git diff #{ref} failed" unless $?.success?

      @changed = self.class.parse(diff)
    end

    def cover?(subject)
      lines = @changed[subject.file.delete_prefix("#{@root}/")]
      return false unless lines

      lines.any? { |line| subject.line_range.cover?(line) }
    end
  end
end
```

Append to `lib/open_mutator.rb`:
```ruby
require_relative "open_mutator/since_filter"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/since_filter_spec.rb`
Expected: 3 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: SinceFilter for git-diff-scoped runs"
```

## Task 18: Config, CLI, Runner

**Files:**
- Create: `lib/open_mutator/config.rb`, `lib/open_mutator/cli.rb`, `lib/open_mutator/runner.rb`
- Test: `spec/open_mutator/cli_spec.rb`, `spec/open_mutator/runner_spec.rb`

- [ ] **Step 1: Write the failing CLI tests**

`spec/open_mutator/cli_spec.rb`:
```ruby
RSpec.describe OpenMutator::CLI do
  describe ".parse" do
    it "builds a default config" do
      config = described_class.parse([])
      expect(config.paths).to eq([])
      expect(config.since).to be_nil
      expect(config.subject_filter).to be_nil
      expect(config.format).to eq(:terminal)
      expect(config.jobs).to be > 0
      expect(config.force_baseline).to be(false)
      expect(config.root).to eq(Dir.pwd)
    end

    it "parses all flags" do
      config = described_class.parse(
        %w[app lib --since origin/main --subject Foo#bar --jobs 4
           --format json --require ./config/environment --force-baseline
           --timeout-factor 3 --timeout-floor 5]
      )
      expect(config.paths).to eq(%w[app lib])
      expect(config.since).to eq("origin/main")
      expect(config.subject_filter).to eq("Foo#bar")
      expect(config.jobs).to eq(4)
      expect(config.format).to eq(:json)
      expect(config.requires).to eq(["./config/environment"])
      expect(config.force_baseline).to be(true)
      expect(config.timeout_factor).to eq(3.0)
      expect(config.timeout_floor).to eq(5.0)
    end
  end

  describe ".run" do
    it "returns exit code 2 with a message on unknown flags" do
      code = nil
      expect { code = described_class.run(["--nope"]) }
        .to output(/invalid option/).to_stderr
      expect(code).to eq(2)
    end
  end
end
```

- [ ] **Step 2: Write the failing Runner tests**

Runner orchestration is unit-tested with all collaborators injected/stubbed; full-stack behavior is covered by the Task 19 E2E.

`spec/open_mutator/runner_spec.rb`:
```ruby
RSpec.describe OpenMutator::Runner do
  let(:config) do
    OpenMutator::Config.new(
      paths: ["lib"], since: nil, subject_filter: nil, jobs: 2, format: :terminal,
      requires: [], timeout_factor: 4.0, timeout_floor: 2.0, force_baseline: false,
      root: "/project"
    )
  end

  let(:subject_) do
    OpenMutator::Subject.new(name: "A#x", file: "/project/lib/a.rb",
                             byte_range: 0...10, line_range: 1..3,
                             constant_scope: "A", kind: :instance)
  end

  def mutation(line: 2)
    OpenMutator::Mutation.new(
      subject: subject_,
      edit: OpenMutator::Edit.new(range: 5...6, replacement: ">=", description: "d"),
      original_snippet: ">", line: line,
      mutated_file_source: "", mutated_def_source: "def x = 1", mutated_def_line: 1
    )
  end

  it "builds work items from covered mutations and reports uncovered ones" do
    covered = mutation(line: 2)
    uncovered = mutation(line: 3)
    map = instance_double(OpenMutator::CoverageMap)
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", 2..2).and_return(["e1"])
    allow(map).to receive(:examples_for).with("/project/lib/a.rb", 3..3).and_return([])
    allow(map).to receive(:time_for).with(["e1"]).and_return(0.5)

    runner = described_class.new(config)
    items, uncovered_results = runner.plan_work([covered, uncovered], map)

    expect(items.size).to eq(1)
    expect(items.first.mutation).to eq(covered)
    expect(items.first.example_ids).to eq(["e1"])
    expect(items.first.timeout).to eq(0.5 * 4.0 + 2.0)
    expect(uncovered_results.map(&:status)).to eq([:uncovered])
  end

  it "exits 1 when mutants survive, 0 otherwise" do
    survived = OpenMutator::Result.new(mutation: mutation, status: :survived, details: nil)
    killed = OpenMutator::Result.new(mutation: mutation, status: :killed, details: nil)
    expect(described_class.new(config).exit_code([killed, survived])).to eq(1)
    expect(described_class.new(config).exit_code([killed])).to eq(0)
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bundle exec rspec spec/open_mutator/cli_spec.rb spec/open_mutator/runner_spec.rb`
Expected: FAIL with uninitialized constant errors

- [ ] **Step 4: Implement**

`lib/open_mutator/config.rb`:
```ruby
require "etc"

module OpenMutator
  Config = Data.define(:paths, :since, :subject_filter, :jobs, :format, :requires,
                       :timeout_factor, :timeout_floor, :force_baseline, :root)
end
```

`lib/open_mutator/cli.rb`:
```ruby
require "optparse"

module OpenMutator
  module CLI
    def self.run(argv)
      Runner.new(parse(argv)).call
    rescue OptionParser::ParseError, Error => e
      warn "open_mutator: #{e.message}"
      2
    end

    def self.parse(argv)
      options = {
        since: nil, subject_filter: nil, jobs: Etc.nprocessors, format: :terminal,
        # Floor must absorb the fork's boot cost (RSpec setup + spec_helper
        # load), not just example runtime — hence 10s, not 2s.
        requires: [], timeout_factor: 4.0, timeout_floor: 10.0, force_baseline: false
      }
      paths = OptionParser.new do |o|
        o.banner = "Usage: open_mutator [paths] [options]"
        o.on("--since REF", "Mutate only methods changed since git REF") { |v| options[:since] = v }
        o.on("--subject NAME", "Mutate only the named subject, e.g. Foo::Bar#baz") { |v| options[:subject_filter] = v }
        o.on("--jobs N", Integer, "Concurrent workers (default: CPU count)") { |v| options[:jobs] = v }
        o.on("--format FMT", %w[terminal json], "Output format") { |v| options[:format] = v.to_sym }
        o.on("--require FILE", "File to require before mutating (repeatable)") { |v| options[:requires] << v }
        o.on("--force-baseline", "Ignore cached coverage map") { options[:force_baseline] = true }
        o.on("--timeout-factor F", Float, "Timeout = baseline time * F + floor") { |v| options[:timeout_factor] = v }
        o.on("--timeout-floor S", Float, "Minimum timeout seconds") { |v| options[:timeout_floor] = v }
      end.parse(argv)

      Config.new(paths: paths, root: Dir.pwd, **options)
    end
  end
end
```

`lib/open_mutator/runner.rb`:
```ruby
module OpenMutator
  class Runner
    def initialize(config, reporter: nil)
      @config = config
      @reporter = reporter || build_reporter
    end

    def call
      preload!
      map = Baseline.new(root: @config.root).coverage_map(force: @config.force_baseline)
      subjects = discover_subjects
      analyses = subjects.map { |s| Engine.new.analyze(s) }
      mutations = analyses.flat_map(&:mutations)
      invalid_count = analyses.sum(&:invalid_count)

      items, uncovered = plan_work(mutations, map)
      uncovered.each { |r| @reporter.on_result(r) }
      scheduler = Scheduler.new(jobs: @config.jobs, on_result: @reporter.method(:on_result))
      results = scheduler.run(items) + uncovered

      @reporter.summary(results, invalid_count: invalid_count)
      exit_code(results)
    end

    # Returns [work_items, uncovered_results]. Public for unit testing.
    def plan_work(mutations, map)
      items = []
      uncovered = []
      mutations.each do |mutation|
        example_ids = map.examples_for(mutation.subject.file, mutation.lines)
        if example_ids.empty?
          uncovered << Result.new(mutation: mutation, status: :uncovered, details: nil)
        else
          timeout = map.time_for(example_ids) * @config.timeout_factor + @config.timeout_floor
          items << WorkItem.new(mutation: mutation, example_ids: example_ids, timeout: timeout)
        end
      end
      [items, uncovered]
    end

    def exit_code(results)
      results.any? { |r| r.status == :survived } ? 1 : 0
    end

    private

    def build_reporter
      @config.format == :json ? Reporter::Json.new : Reporter::Terminal.new
    end

    def preload!
      @config.requires.each { |f| require File.expand_path(f, @config.root) }
      environment = File.join(@config.root, "config", "environment.rb")
      if @config.requires.empty? && File.exist?(environment)
        require environment
        Rails.application.eager_load! if defined?(Rails)
      end
    end

    def discover_subjects
      paths = @config.paths.empty? ? default_paths : @config.paths
      subjects = paths
        .flat_map { |p| Dir[File.join(@config.root, p, "**", "*.rb")] }
        .sort.flat_map { |file| SubjectFinder.call(file) }
      subjects = subjects.select { |s| s.name == @config.subject_filter } if @config.subject_filter
      if @config.since
        filter = SinceFilter.new(ref: @config.since, root: @config.root)
        subjects = subjects.select { |s| filter.cover?(s) }
      end
      subjects
    end

    def default_paths
      %w[app lib].select { |p| Dir.exist?(File.join(@config.root, p)) }
    end
  end
end
```

Append to `lib/open_mutator.rb` (final require list):
```ruby
require_relative "open_mutator/config"
require_relative "open_mutator/runner"
require_relative "open_mutator/cli"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/open_mutator/cli_spec.rb spec/open_mutator/runner_spec.rb`
Expected: 5 examples, 0 failures

- [ ] **Step 6: Run whole suite**

Run: `bundle exec rspec`
Expected: all pass

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: Config, CLI, and Runner orchestration"
```

---

# Phase 6 — End-to-End & Property Gate

## Task 19: tiny_project E2E

**Files:**
- Test: `spec/e2e/tiny_project_spec.rb` (tagged `:e2e`)

**Prerequisite:** the fixture's bundle must be installed (done once in Task 12 Step 1). Fresh clones/CI must run `cd spec/fixtures/tiny_project && BUNDLE_GEMFILE=Gemfile bundle install` before the tagged suite.

- [ ] **Step 1: Write the E2E test**

`spec/e2e/tiny_project_spec.rb`:
```ruby
require "json"
require "open3"
require "fileutils"

RSpec.describe "tiny_project end-to-end", :e2e do
  let(:root) { File.expand_path("../fixtures/tiny_project", __dir__) }

  after { FileUtils.rm_rf(File.join(root, ".open_mutator")) }

  it "kills tested mutants, surfaces the planted survivor and uncovered method" do
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
        "bundle", "exec", "open_mutator", "lib", "--format", "json", "--jobs", "2",
        chdir: root
      )
    end

    data = JSON.parse(stdout)
    results = data.fetch("results")

    survivors = results.select { |r| r["status"] == "survived" }
    expect(survivors.map { |r| [r["subject"], r["description"]] })
      .to contain_exactly(
        ["Calculator#discount", "replace `<` with `<=`"],
        ["Calculator#discount", "replace `100` with `101`"]
      ), stderr

    eligible = results.select { |r| r["subject"] == "Calculator#eligible?" }
    expect(eligible).not_to be_empty
    expect(eligible.map { |r| r["status"] }.uniq).to eq(["killed"])

    uncovered = results.select { |r| r["status"] == "uncovered" }
    expect(uncovered.map { |r| r["subject"] }.uniq).to eq(["Calculator#untested_helper"])

    expect(status.exitstatus).to eq(1) # survivors present
  end
end
```

- [ ] **Step 2: Run it**

Run: `OPEN_MUTATOR_E2E=1 bundle exec rspec spec/e2e/tiny_project_spec.rb`
Expected: PASS. This is the whole pipeline; debugging lands here. Common failure causes, in order: coverage map path/keying mismatches (absolute vs relative), def-span extraction, worker exit protocol.

If a status assertion fails, debug with the terminal format inside the fixture:
`cd spec/fixtures/tiny_project && BUNDLE_GEMFILE=Gemfile bundle exec open_mutator lib`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test: end-to-end pipeline against tiny_project fixture"
```

## Task 20: Property gate — every emitted mutant re-parses

**Files:**
- Test: `spec/property/reparse_spec.rb`

- [ ] **Step 1: Write the property test**

Corpus = open_mutator's own `lib/`. Every operator, every node, every emitted edit: the mutated file must re-parse. This asserts operators produce position-valid replacements — the Engine's gate discards failures at runtime, but a failure here is an operator bug to fix, not to discard.

`spec/property/reparse_spec.rb`:
```ruby
RSpec.describe "operator re-parse property" do
  def each_node(node, &blk)
    yield node
    node.compact_child_nodes.each { |child| each_node(child, &blk) }
  end

  Dir[File.expand_path("../../lib/**/*.rb", __dir__)].sort.each do |file|
    it "all mutants of #{File.basename(file)} re-parse" do
      source = File.read(file)
      result = Prism.parse(source)
      expect(result.success?).to be(true)

      failures = []
      each_node(result.value) do |node|
        OpenMutator::Operators::Base.all.each do |operator|
          operator.edits(node).each do |edit|
            mutated = OpenMutator::Splicer.apply(source, [edit])
            unless Prism.parse(mutated).success?
              failures << "#{operator.class}: #{edit.description} @ bytes #{edit.range}"
            end
          end
        end
      end
      expect(failures).to eq([])
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `bundle exec rspec spec/property/reparse_spec.rb`
Expected: PASS. If an operator fails, tighten its `applies?`-style guards (the fix belongs in the operator, mirroring the heredoc/interpolation guards in `Literal`).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test: property gate — all emitted mutants re-parse"
```

## Task 21: Minimal Rails fixture E2E

**Files:**
- Create: `spec/fixtures/rails_app/` (generated)
- Test: `spec/e2e/rails_app_spec.rb` (tagged `:rails_e2e`)

Proves the Rails-specific claims: environment preload, fork-safe ActiveRecord reconnect, DB-touching specs killing mutants.

- [ ] **Step 1: Generate the fixture app**

```bash
cd spec/fixtures
gem exec rails new rails_app --minimal --skip-git --skip-bundle --skip-docker --skip-ci
cd rails_app
```

Notes:
- `--skip-ci` requires Rails ≥ 7.2 — if `gem exec` resolves an older Rails, drop the flag.
- The E2E uses `--jobs 1` deliberately: two forks sharing one SQLite test database invites intermittent lock errors, and concurrency is already proven by the tiny_project E2E.

Append to `spec/fixtures/rails_app/Gemfile`:
```ruby
gem "rspec-rails", group: %i[development test]
gem "open_mutator", path: "../../.."
```

```bash
bundle install
bundle exec rails generate rspec:install
bundle exec rails generate model User age:integer
bundle exec rails db:migrate
```

- [ ] **Step 2: Add the mutable model method and spec**

Edit `spec/fixtures/rails_app/app/models/user.rb` to:
```ruby
class User < ApplicationRecord
  def adult?
    age >= 18
  end

  def self.adults
    where("age >= ?", 18)
  end
end
```

`spec/fixtures/rails_app/spec/models/user_spec.rb`:
```ruby
require "rails_helper"

RSpec.describe User do
  describe "#adult?" do
    it { expect(User.new(age: 18).adult?).to be(true) }
    it { expect(User.new(age: 17).adult?).to be(false) }
  end

  describe ".adults" do
    it "queries the database" do
      User.create!(age: 20)
      User.create!(age: 10)
      expect(User.adults.count).to eq(1)
    end
  end
end
```

Verify fixture suite: `cd spec/fixtures/rails_app && bundle exec rspec`
Expected: 3 examples, 0 failures. Then `cd -`.

- [ ] **Step 3: Write the E2E test**

`spec/e2e/rails_app_spec.rb`:
```ruby
require "json"
require "open3"
require "fileutils"

RSpec.describe "rails_app end-to-end", :rails_e2e do
  let(:root) { File.expand_path("../fixtures/rails_app", __dir__) }

  after { FileUtils.rm_rf(File.join(root, ".open_mutator")) }

  it "mutates an ActiveRecord model with DB-touching specs" do
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "RAILS_ENV" => "test" },
        "bundle", "exec", "open_mutator", "app", "--format", "json", "--jobs", "1",
        chdir: root
      )
    end

    data = JSON.parse(stdout)
    adult = data.fetch("results").select { |r| r["subject"] == "User#adult?" }
    expect(adult).not_to be_empty, stderr
    boundary = adult.find { |r| r["description"] == "replace `>=` with `>`" }
    expect(boundary["status"]).to eq("killed") # spec covers exactly 18

    # No :error statuses — proves fork + AR reconnect hygiene works:
    expect(data.fetch("results").map { |r| r["status"] }).not_to include("error")
    expect(status.exitstatus).to be_between(0, 1)
  end
end
```

- [ ] **Step 4: Run it**

Run: `OPEN_MUTATOR_RAILS_E2E=1 bundle exec rspec spec/e2e/rails_app_spec.rb`
Expected: PASS. If `error` statuses appear, debug `Worker#after_fork_hygiene` (AR connection handling API differs across Rails versions — adjust to the generated app's Rails version).

- [ ] **Step 5: Full suite, all tags**

Run: `OPEN_MUTATOR_INTEGRATION=1 OPEN_MUTATOR_E2E=1 OPEN_MUTATOR_RAILS_E2E=1 bundle exec rspec`
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "test: Rails fixture end-to-end — preload, fork hygiene, DB kill path"
```

---

## Post-v1 backlog (explicitly out of scope, from spec)

minitest integration · operator plugin API · fine-grained baseline invalidation · full subject-expression language · HTML report · Windows support · per-method opt-out magic comment (spec lists it; deferred out of v1 — add as first post-v1 item) · path exclude globs (spec lists include/exclude; v1 ships include-only) · broader Enumerable call-swap pack · `--since` coverage of untracked files · `class << self` bodies · nested defs · heredoc string mutations · timeout budget that measures in-fork boot cost instead of relying on the floor.
