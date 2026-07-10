module ActiveMutator
  # flock-guarded write-to-temp + rename. Concurrent runs in one repo (an
  # agent plus a human — the dev-loop case) must not corrupt cache or ledger.
  module AtomicFile
    def self.write(path, content)
      File.open("#{path}.lock", File::CREAT | File::RDWR, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        tmp = "#{path}.tmp#{Process.pid}"
        File.write(tmp, content)
        File.rename(tmp, path)
      end
      nil
    end
  end
end
