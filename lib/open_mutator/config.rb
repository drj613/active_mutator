require "etc"

module OpenMutator
  Config = Data.define(:paths, :since, :subject_filter, :jobs, :format, :requires,
                       :timeout_factor, :timeout_floor, :force_baseline, :root)
end
