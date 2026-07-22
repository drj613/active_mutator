require "tmpdir"

RSpec.describe ActiveMutator::ClosureReload do
  # Each example gets disposable real constants: sources written to tmp
  # files and eval'd with correct __FILE__ attribution, so
  # const_source_location points at the tmp file (the reopen guard checks it).
  let(:dir) { Dir.mktmpdir }
  let(:defined_names) { [] }

  # ClosureReload scans every Module in ObjectSpace. Other specs (e.g.
  # worker_spec) create RSpec verifying doubles, which ARE Modules and linger
  # as expired garbage until collected; touching one raises an Exception-level
  # error the scan should never have to see. Collect them before we scan.
  before { GC.start }

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
    result = described_class.new(subject_for(file, "CrAlpha"), mutated).call
    expect(result).to be_nil
    expect(CrAlpha::RATE).to eq(9)
    expect(CrAlpha.new.rate).to eq(9)
    # Re-eval attributes the constant to line 1 of its file (eval lineno 1).
    expect(Object.const_source_location("CrAlpha")).to eq([file, 1])
  end

  it "removes the old constant before re-eval so stale members do not linger" do
    file = load_source("cr_stale.rb", <<~RUBY, top_const: :CrStale)
      class CrStale
        GONE = 1
        KEPT = 2
      end
    RUBY
    # Mutated source drops GONE. Only a remove_const before re-eval makes it
    # vanish; a plain reopen would leave the old GONE defined.
    mutated = File.read(file).sub("  GONE = 1\n", "")
    described_class.new(subject_for(file, "CrStale"), mutated).call
    expect(CrStale.const_defined?(:GONE, false)).to be(false)
    expect(CrStale::KEPT).to eq(2)
  end

  it "applies a closure exactly at the cap (boundary is exclusive)" do
    mod_file = load_source("cr_cap.rb", <<~RUBY, top_const: :CrCap)
      module CrCap
        LIMIT = 5
        def limit = LIMIT
      end
    RUBY
    load_source("cr_cap_host.rb", <<~RUBY, top_const: :CrCapHost)
      class CrCapHost
        include CrCap
      end
    RUBY
    mutated = File.read(mod_file).sub("LIMIT = 5", "LIMIT = 7")
    # Closure is exactly 2 (module + one includer); cap 2 must NOT skip.
    described_class.new(subject_for(mod_file, "CrCap"), mutated).call(cap: 2)
    expect(CrCapHost.new.limit).to eq(7)
  end

  it "reloads a deeply nested constant, resolving its parent scope" do
    file = load_source("cr_nested.rb", <<~RUBY, top_const: :CrN1)
      module CrN1
        module CrN2
          class CrN3
            VALUE = 1
          end
        end
      end
    RUBY
    subject = ActiveMutator::SubjectFinder.call(file).find do |s|
      s.class_body? && s.constant_scope == "CrN1::CrN2::CrN3"
    end || raise("no CrN1::CrN2::CrN3 subject")
    mutated = File.read(file).sub("VALUE = 1", "VALUE = 4")
    described_class.new(subject, mutated).call
    expect(CrN1::CrN2::CrN3::VALUE).to eq(4)
  end

  it "skips when the constant is native (no source location)" do
    subject = ActiveMutator::Subject.new(
      name: "Comparable (class body)", file: "/no/such/file.rb",
      byte_range: 0...1, line_range: 1..1,
      constant_scope: "Comparable", kind: :class_body
    )
    expect { described_class.new(subject, "module Comparable\nend\n").call }
      .to raise_error(described_class::Skip, /defined at \?/)
  end

  it "skips when a plain object instance is extended with the target" do
    mod_file = load_source("cr_obj_ext.rb", <<~RUBY, top_const: :CrObjExt)
      module CrObjExt
        FLAG = 1
        def tag = "x"
      end
    RUBY
    obj = Object.new
    obj.extend(CrObjExt)
    subject = subject_for(mod_file, "CrObjExt")
    expect { described_class.new(subject, File.read(mod_file)).call }
      .to raise_error(described_class::Skip, /object instance is extended/)
    obj # keep alive past the call
  end

  it "skips when an anonymous module is in the closure" do
    mod_file = load_source("cr_anon_mod_target.rb", <<~RUBY, top_const: :CrAnonModTarget)
      module CrAnonModTarget
        LIMIT = 5
      end
    RUBY
    anon = Module.new { include CrAnonModTarget }
    subject = subject_for(mod_file, "CrAnonModTarget")
    expect { described_class.new(subject, File.read(mod_file)).call }
      .to raise_error(described_class::Skip, /anonymous module/)
    anon # keep alive past the call
  end

  it "skips when an attacher has no on-disk source file" do
    mod_file = load_source("cr_evalhost_target.rb", <<~RUBY, top_const: :CrEvalHostTarget)
      module CrEvalHostTarget
        LIMIT = 5
      end
    RUBY
    eval(<<~RUBY, TOPLEVEL_BINDING, "(not a real file)", 1) # rubocop:disable Security/Eval
      class CrEvalHost
        include CrEvalHostTarget
      end
    RUBY
    defined_names << :CrEvalHost
    subject = subject_for(mod_file, "CrEvalHostTarget")
    expect { described_class.new(subject, File.read(mod_file)).call }
      .to raise_error(described_class::Skip, /no source file/)
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

  it "reloads a multi-level closure in dependency order (no NameError)" do
    chain_file = load_source("cr_chain.rb", <<~RUBY, top_const: :CrChain)
      module CrChain
        RATE = 5
        def rate = RATE
      end
    RUBY
    load_source("cr_mid.rb", <<~RUBY, top_const: :CrMid)
      class CrMid
        include CrChain
      end
    RUBY
    load_source("cr_leaf.rb", <<~RUBY, top_const: :CrLeaf)
      class CrLeaf < CrMid
      end
    RUBY
    mutated = File.read(chain_file).sub("RATE = 5", "RATE = 9")
    described_class.new(subject_for(chain_file, "CrChain"), mutated).call
    # Mutation reached the leaf through the mid, and the class graph survived
    # re-eval (superclass must be reloaded before its subclass).
    expect(CrLeaf.new.rate).to eq(9)
    expect(CrLeaf.superclass).to eq(CrMid)
    expect(CrMid.include?(CrChain)).to be(true)
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

  it "reloads an extender whose instance-ancestor depth is below the target's" do
    load_source("cr_ext_base.rb", <<~RUBY, top_const: :CrExtBase)
      module CrExtBase
        BASE = 1
      end
    RUBY
    # Target INCLUDES another module, so its instance-ancestor depth (>= 2)
    # exceeds the extender's — an ancestors.size-only sort would load the
    # extender first and NameError. Target-first ordering must fix it.
    target_file = load_source("cr_ext_target.rb", <<~RUBY, top_const: :CrExtTarget)
      module CrExtTarget
        include CrExtBase
        TAG = "v1"
        def tag = TAG
      end
    RUBY
    # A MODULE extender: its instance ancestry is just [CrExtender] (size 1),
    # below the target's size 2, so an ancestors.size-only sort loads it first.
    load_source("cr_extender.rb", <<~RUBY, top_const: :CrExtender)
      module CrExtender
        extend CrExtTarget
      end
    RUBY
    mutated = File.read(target_file).sub('TAG = "v1"', 'TAG = "v2"')
    described_class.new(subject_for(target_file, "CrExtTarget"), mutated).call
    expect(CrExtender.tag).to eq("v2")
    expect(CrExtender.singleton_class.include?(CrExtTarget)).to be(true)
  end

  it "reloads extenders (extend sites appear as singleton-class attachers)" do
    mod_file = load_source("cr_ext.rb", <<~RUBY, top_const: :CrExt)
      module CrExt
        VERSION = 1
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

  it "ignores modules in ObjectSpace that cannot be introspected" do
    file = load_source("cr_introspect.rb", <<~RUBY, top_const: :CrIntrospect)
      class CrIntrospect
        RATE = 5
        def rate = RATE
      end
    RUBY
    # A leaked/expired test double: #ancestors raises. The whole-VM scan must
    # skip it rather than crash the reload.
    bad = Module.new
    def bad.ancestors = raise("expired double")
    mutated = File.read(file).sub("RATE = 5", "RATE = 8")
    described_class.new(subject_for(file, "CrIntrospect"), mutated).call
    expect(CrIntrospect::RATE).to eq(8)
    bad # keep alive past the call
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
      .to raise_error(described_class::Skip, /anonymous class/)
    anon # keep the reference alive past the call
  end

  it "skips when an attacher's file defines multiple constants" do
    mod_file = load_source("cr_multi_target.rb", <<~RUBY, top_const: :CrMultiTarget)
      module CrMultiTarget
        LIMIT = 5
      end
    RUBY
    # Second top-level constant is a MODULE so the count guard cannot be
    # satisfied by matching ClassNode alone.
    load_source("cr_multi_host.rb", <<~RUBY, top_const: :CrMultiHostA)
      class CrMultiHostA
        include CrMultiTarget
      end
      module CrMultiHostB
      end
    RUBY
    defined_names << :CrMultiHostB
    subject = subject_for(mod_file, "CrMultiTarget")
    expect { described_class.new(subject, File.read(mod_file)).call }
      .to raise_error(described_class::Skip, /defines .*constants|multiple top-level/)
  end
end
