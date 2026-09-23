module ActiveMutator
  # Reads process memory for run diagnostics. `proc_root` is injectable so
  # specs read fixture files instead of the live /proc.
  module MemoryProbe
    # `extend self`, not `module_function`: see ClassShape.
    extend self

    # This process's peak RSS in KB (VmHWM). A worker can exit between two
    # memory samples, so it reports its own peak. nil off Linux.
    def peak_rss_kb(proc_root: "/proc")
      status_kb(File.join(proc_root, "self", "status"), "VmHWM")
    end

    def status_kb(path, key)
      line = File.foreach(path).find { |l| l.start_with?("#{key}:") }
      line && line[/\d+/].to_i
    rescue SystemCallError
      nil
    end
  end
end
