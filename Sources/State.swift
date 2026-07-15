import Foundation

struct DaemonState {
    let pidPath: String
    var lockFD: Int32

    init(dataDir: String) {
        self.pidPath = "\(dataDir)/daemon.pid"
        self.lockFD = -1
    }

    func isRunning() -> Bool {
        guard let pid = readPID() else { return false }
        guard kill(pid, 0) == 0 else {
            try? FileManager.default.removeItem(atPath: pidPath)
            return false
        }
        return processIsMsl(pid)
    }

    func readPID() -> pid_t? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidPath)),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(str) else { return nil }
        return pid
    }

    /// Acquire an exclusive flock on the PID file and hold it for our
    /// entire lifetime.  This prevents a second daemon from starting
    /// while we are alive, even if our PID file is briefly absent.
    mutating func writePID() throws {
        let fd = open(pidPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw MslError("cannot create PID file: \(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw MslError("another msl start is already running (lock held)")
        }
        let pid = getpid()
        try "\(pid)".write(toFile: pidPath, atomically: true, encoding: .utf8)
        lockFD = fd
    }

    mutating func removePID() {
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    private func processIsMsl(_ pid: pid_t) -> Bool {
        let commPath = "/proc/\(pid)/comm"
        if FileManager.default.fileExists(atPath: commPath) {
            if let data = try? String(contentsOfFile: commPath, encoding: .utf8) {
                return data.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("msl")
            }
        }
        let result = shellOutput("ps -p \(pid) -o comm= 2>/dev/null")
        return result.contains("msl") && !result.contains("grep")
    }
}
