# Custom Operators

Register your own mutation operators without patching the gem.

## Writing an operator

Subclass `ActiveMutator::Operators::Base`. Subclassing IS registration — the base class tracks every subclass and the engine instantiates them all.

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

- `edit(range, replacement, description)` — build an edit. `range` is an exclusive **byte** range into the original file source; `replacement` is the literal text spliced in; `description` appears in reports.
- `loc_range(loc)` — convert a Prism location to that byte range.

Every mutated file is re-parsed before use; an edit producing invalid Ruby is dropped and counted, never run.

## Loading

CLI (repeatable):

    active_mutator lib --operator ops/nil_guard.rb

Or `.active_mutator.yml`:

```yaml
operators:
  - ops/nil_guard.rb
```

Paths resolve against the project root. Files load in the parent process before analysis, so `--require`d app code is NOT yet loaded — operators must be self-contained (Prism is available).

## Stability policy

Public and semver-stable from 0.2:

- `ActiveMutator::Operators::Base` subclass-registration, `#edits(node)`, `#edit`, `#loc_range`
- `ActiveMutator::Edit` members (`range`, `replacement`, `description`, `operator`)

The `node` argument is a Prism AST node: its API follows the `prism` gem, not this one. Pin `prism` if you need parser-level stability.
