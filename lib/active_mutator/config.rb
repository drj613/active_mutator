require "etc"

module ActiveMutator
  Config = Data.define(:paths, :since, :subject_filter, :jobs, :format, :requires,
                       :timeout_factor, :timeout_floor, :force_baseline, :root,
                       :preload_helper, :serial_patterns, :spec_paths,
                       :browser_boot_seconds,
                       :accept_survivors, :exclude, :max_mutants, :debug_plan,
                       :fail_at, :adaptive_timeout, :operators,
                       :class_level, :class_level_closure_cap, :allow_empty,
                       :diagnostics, :events_file, :sample_interval, :max_rss, :audit_tests,
                       :fail_on_no_kills, :incremental) do
    # Defaults for the fields added since 0.7.0, so a Config built by hand
    # (specs, embedding hosts) doesn't have to name them. `max_rss` is in kB.
    def initialize(diagnostics: false, events_file: nil, sample_interval: 5.0, max_rss: nil, audit_tests: false,
                   fail_on_no_kills: false, incremental: false, **fields)
      super
    end
  end
end
