import Foundation

struct DaemonState {
    let pidPath: String
    let deadMarkerPath: String
    var lockFD: Int32
    let dataDir: String

    init(dataDir: String) {
        self.pidPath = "\(dataDir)/daemon.pid"
        self.deadMarkerPath = "\(dataDir)/vm.dead"
        self.lockFD = -1
        self.dataDir = dataDir
    }

    func isRunning() -> Bool {
        guard let pid = readPID() else { return false }
        guard processIsMsl(pid) else {
            try? FileManager.default.removeItem(atPath: pidPath)
            return false
        }
        return !FileManager.default.fileExists(atPath: deadMarkerPath)
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
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else {
            try? FileManager.default.removeItem(atPath: pidPath)
            return false
        }
        let path = String(cString: buf)
        return path.hasSuffix("/msl")
    }
}
