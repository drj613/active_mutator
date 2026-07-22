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
  #
  # Known limitations (inherent to remove-and-reload; accepted trade-offs):
  #   - References that hold the target BY VALUE rather than by ancestry are
  #     not discovered and keep pointing at the pre-remove_const object:
  #     aliases (`ALIAS = MyClass`), arrays/registries the target was pushed
  #     into, memoized instances, class variables captured at load time.
  #   - `refine`-based modules are anonymous and do not appear in normal
  #     `ancestors`, so refinements of the target are not discovered/reloaded.
  #   - The re-eval order pins the target first (every attacher depends on it)
  #     then sorts the rest by instance-ancestor depth. An `extend`
  #     relationship BETWEEN two non-target attachers can still re-eval out of
  #     order (rare); a full topological sort is deliberately not attempted.
  class ClosureReload
    Skip = Class.new(StandardError)

    # The MUTATED target source could not be re-evaled — the mutation broke the
    # class so it no longer loads. Every covering spec loads the class, so the
    # suite would fail: the Worker maps this to a kill, not an error.
    MutantLoadError = Class.new(StandardError)

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

      # Re-eval must load dependencies before dependents. Every closure member
      # carries the target directly (single-pass discovery invariant), so the
      # target must be re-eval'd first — pin it to the front. `ancestors.size`
      # can't do this alone: an `extend` puts the target in the extender's
      # SINGLETON ancestry, so a module that extends the target has an instance
      # ancestry SMALLER than the target's and would sort before it (NameError
      # on re-eval). For the remaining attachers, ascending instance-ancestor
      # depth is a valid order among include/subclass relationships (a
      # superclass before its subclass, an included module before its
      # includer); depth is captured while the constants are still live, since
      # it can't be read after remove_const.
      rest = closure.reject { |m| m.equal?(target) }
      ordered = [target, *rest.sort_by { |m| m.ancestors.size }]
      sources = ordered.map { |mod| [mod.name, source_for(mod)] }
      sources.each { |name, _| remove_constant(name) }
      sources.each_with_index do |(_, (file, src)), idx|
        eval(src, TOPLEVEL_BINDING, file, 1) # rubocop:disable Security/Eval
      rescue ScriptError, StandardError => e
        # idx.zero? is the MUTATED target, which by construction depends on
        # nothing else in the closure (every other member carries the target,
        # not vice versa). Its source failing to load is therefore the
        # mutation's own doing — a kill, not a tool error.
        #
        # A PRISTINE dependent (idx > 0) failing means the ancestry-depth order
        # couldn't satisfy a cross-attacher reference (see the ordering note
        # above): we can't faithfully reinstate the closure, so this is an
        # honest Skip, not a survived/killed verdict and not a bare error.
        raise MutantLoadError, e.message if idx.zero?

        raise Skip, "reload re-eval failed (#{e.message}); closure could not be reinstated in dependency order"
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

    # Single discovery pass. Ruby's `ancestors` is transitive, so one scan for
    # everything carrying the target already yields every transitive attacher:
    # an attacher-of-an-attacher (a subclass of an includer, an includer of an
    # includer) carries the target directly too. No BFS/dedup is needed — the
    # dependency-correct re-eval order is imposed later by topological sort,
    # not by discovery order.
    def compute_closure(target)
      [target, *attachers(target)]
    end

    # Everything stale after removing `mod`: includers and subclasses carry
    # it in `ancestors`; extend-sites carry it in their singleton class's
    # ancestors, so singleton classes map back through attached_object. `.uniq`
    # collapses a member found both ways (a class that both includes and
    # extends the target).
    def attachers(mod)
      ObjectSpace.each_object(Module).filter_map do |m|
        next if m.equal?(mod)
        next unless carries?(m, mod)

        if m.singleton_class?
          m = m.attached_object
          unless m.is_a?(Module)
            raise Skip, "an object instance is extended with #{mod.name || mod.inspect}; not reloadable"
          end
        end

        m
      end.uniq
    end

    # ObjectSpace hands back every Module in the VM, including ones we cannot
    # introspect — e.g. a module whose #ancestors is overridden to raise. A
    # module we cannot read is not a reloadable dependency of the target, so
    # treat it as unrelated rather than aborting the whole scan. Trade-off: a
    # genuine attacher whose #ancestors raises would be silently dropped
    # (acceptable — pathological).
    #
    # The rescue is deliberately broader than StandardError: #ancestors on a
    # foreign object can raise Exception-level errors that are NOT StandardError
    # — the canonical case is an expired RSpec verifying double
    # (ExpiredTestDoubleError < MockExpectationError < Exception) left in
    # ObjectSpace by another spec. Only genuinely fatal control-flow errors
    # (signals, exit, out-of-memory) are re-raised so a run stays interruptible.
    def carries?(mod, target)
      mod.ancestors.include?(target)
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise if e.is_a?(SignalException) || e.is_a?(SystemExit) || e.is_a?(NoMemoryError)

      false
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
    # that were NOT removed (accumulation bugs). Shared with SubjectFinder.
    def single_constant_file?(source)
      result = Prism.parse(source)
      return false unless result.success?

      ClassShape.single_top_level_constant?(result.value)
    end

    def remove_constant(name)
      parts = name.split("::")
      leaf = parts.pop
      parent = parts.empty? ? Object : Object.const_get(parts.join("::"))
      parent.send(:remove_const, leaf) if parent.const_defined?(leaf, false)
    rescue NameError
      # A parent namespace earlier in the closure was already removed, taking
      # this nested constant with it. Nothing to remove — the re-eval pass
      # reinstates it from its own file.
    end
  end
end
