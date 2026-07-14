import Foundation

struct DaemonState {
    let pidPath: String

    init(dataDir: String) {
        self.pidPath = "\(dataDir)/daemon.pid"
    }

    func isRunning() -> Bool {
        guard let pid = readPID() else { return false }
        return kill(pid, 0) == 0
    }

    func readPID() -> pid_t? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidPath)),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(str) else { return nil }
        return pid
    }

    func writePID() throws {
        let pid = getpid()
        try "\(pid)".write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    func removePID() {
        try? FileManager.default.removeItem(atPath: pidPath)
    }
}
