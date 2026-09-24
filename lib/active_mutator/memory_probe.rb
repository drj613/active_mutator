module ActiveMutator
  # Reads process and system memory for run diagnostics and --max-rss.
  #
  #   Linux: /proc/<pid>/status (VmRSS, VmHWM) and smaps_rollup (Pss), plus
  #          meminfo, pressure/memory, and loadavg for the system fields.
  #   macOS: one `ps -o pid=,rss=` per call for every pid; no peak, Pss, or
  #          system fields.
  #   other: nothing; diagnostics still print, memory fields blank.
  #
  # `proc_root`, `platform`, and `ps` are injectable so specs read fixtures.
  class MemoryProbe
    DEFAULT_PS = lambda do |pids|
      IO.popen(["ps", "-o", "pid=,rss=", "-p", pids.join(",")], err: File::NULL, &:read)
    end

    # This process's peak RSS in KB (VmHWM). A worker can exit between two
    # memory samples, so it reports its own peak. nil off Linux.
    def self.peak_rss_kb(proc_root: "/proc")
      status_kb(File.join(proc_root, "self", "status"), "VmHWM")
    end

    def self.status_kb(path, key)
      line = File.foreach(path).find { |l| l.start_with?("#{key}:") }
      line && line[/\d+/].to_i
    rescue SystemCallError
      nil
    end

    def initialize(proc_root: "/proc", platform: RUBY_PLATFORM, ps: DEFAULT_PS)
      @proc_root = proc_root
      @ps = ps
      @mode = if File.directory?(proc_root) then :linux
              elsif platform.include?("darwin") then :ps
              end
    end

    # {pid => {rss_kb:, hwm_kb:, pss_kb:}}; pids that are gone are left out.
    def processes(pids)
      case @mode
      when :linux then pids.filter_map { |pid| linux_process(pid) }.to_h
      when :ps then pids.empty? ? {} : ps_processes(pids)
      else {}
      end
    end

    # Linux only; nil elsewhere. Each field is nil when its file is missing.
    def system
      return unless @mode == :linux

      meminfo = File.join(@proc_root, "meminfo")
      { mem_available_kb: self.class.status_kb(meminfo, "MemAvailable"),
        swap_total_kb: self.class.status_kb(meminfo, "SwapTotal"),
        swap_free_kb: self.class.status_kb(meminfo, "SwapFree"),
        psi_some_avg10: read(File.join("pressure", "memory"))&.[](/^some avg10=([\d.]+)/, 1)&.to_f,
        load1: read("loadavg")&.split&.first&.to_f }
    end

    private

    def linux_process(pid)
      status = File.join(@proc_root, pid.to_s, "status")
      rss = self.class.status_kb(status, "VmRSS")
      return unless rss

      [pid, { rss_kb: rss, hwm_kb: self.class.status_kb(status, "VmHWM"),
              pss_kb: self.class.status_kb(File.join(@proc_root, pid.to_s, "smaps_rollup"), "Pss") }]
    end

    def ps_processes(pids)
      @ps.call(pids).lines.to_h do |line|
        pid, rss = line.split.map(&:to_i)
        [pid, { rss_kb: rss, hwm_kb: nil, pss_kb: nil }]
      end
    end

    def read(rel)
      File.read(File.join(@proc_root, rel))
    rescue SystemCallError
      nil
    end
  end
end
