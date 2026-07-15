require "etc"

module ActiveMutator
  Config = Data.define(:paths, :since, :subject_filter, :jobs, :format, :requires,
                       :timeout_factor, :timeout_floor, :force_baseline, :root,
                       :preload_helper, :serial_patterns, :browser_boot_seconds,
                       :accept_survivors, :exclude, :max_mutants, :debug_plan)
end
