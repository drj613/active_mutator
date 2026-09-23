require "etc"

module ActiveMutator
  Config = Data.define(:paths, :since, :subject_filter, :jobs, :format, :requires,
                       :timeout_factor, :timeout_floor, :force_baseline, :root,
                       :preload_helper, :serial_patterns, :spec_paths,
                       :browser_boot_seconds,
                       :accept_survivors, :exclude, :max_mutants, :debug_plan,
                       :fail_at, :adaptive_timeout, :operators,
                       :class_level, :class_level_closure_cap, :allow_empty,
                       :diagnostics, :events_file) do
    # Defaults for the 0.7.0 diagnostics fields, so a Config built by hand
    # (specs, embedding hosts) doesn't have to name them.
    def initialize(diagnostics: false, events_file: nil, **fields)
      super
    end
  end
end
