import Foundation
import Virtualization
import os.lock

/// Box to carry vsock connection result across task boundaries without
/// triggering Swift 6 Sendable warnings for UnsafeMutableRawPointer.
private final class VsockConnectBox: @unchecked Sendable {
    var handle: UnsafeMutableRawPointer?
    var fd: Int32 = -1
}

class Daemon {
    let vm: MSLVM
    var state: DaemonState
    let ipc: IPCServer
    let dataDir: String
    var shouldKeepRunning = true
    var sigSourceTerm: DispatchSourceSignal?
    var sigSourceInt: DispatchSourceSignal?
    var shellListenerSock: Int32 = -1

    /// Cap concurrent shell/exec sessions to avoid exhausting the
    /// guest's MAX_FORKS (64) or Swift's cooperative thread pool.
    private var sessionLimit = os_unfair_lock()
    private var activeSessions = 0
    private let maxSessions = 64

    private func acquireSession() -> Bool {
        os_unfair_lock_lock(&sessionLimit)
        defer { os_unfair_lock_unlock(&sessionLimit) }
        guard activeSessions < maxSessions else { return false }
        activeSessions += 1
        return true
    }

    private func releaseSession() {
        os_unfair_lock_lock(&sessionLimit)
        activeSessions -= 1
        os_unfair_lock_unlock(&sessionLimit)
    }

    init(dataDir: String) {
        signal(SIGPIPE, SIG_IGN)
        self.dataDir = dataDir
        self.vm = MSLVM(dataDir: dataDir)
        self.state = DaemonState(dataDir: dataDir)
        self.ipc = IPCServer(path: "\(dataDir)/msld.sock")
    }

    func requestStop() {
        mslLog("received shutdown signal")
        sigSourceTerm?.cancel()
        sigSourceInt?.cancel()
        stopShellListener()
        killSocat()
        // Attempt clean VM shutdown with 5s timeout so the guest
        // gets a clean ACPI power-off even during early boot.
        Task.detached {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.vm.stop() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch { }
            self.shouldKeepRunning = false
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func run() async throws {
        if state.isRunning() {
            throw MslError("daemon already running (pid \(state.readPID() ?? 0))")
        }

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in self?.requestStop() }
        termSource.activate()
        sigSourceTerm = termSource

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in self?.requestStop() }
        intSource.activate()
        sigSourceInt = intSource

        try state.writePID()
        defer {
            sigSourceTerm?.cancel()
            sigSourceInt?.cancel()
            ipc.stop()
            stopShellListener()
            killSocat()
            state.removePID()
        }

        try? FileManager.default.removeItem(atPath: "\(dataDir)/vm.dead")
        ensureDisplayBridge()

        mslLog("booting VM")
        try vm.boot()

        do { try await vm.start()
        } catch {
            mslLog("vm.start failed: \(error.localizedDescription)")
            throw error
        }

        do { try await waitForGuest(timeout: 120)
        } catch {
            mslLog("waitForGuest failed: \(error.localizedDescription)")
            throw error
        }

        try ipc.start { [weak self] requestData, send in
            self?.handleRequest(requestData, send: send)
        }

        startShellListener()

        // Signal readiness *after* IPC + shell sockets are live, so
        // the CLI's startDaemonInBackground loop doesn't find the
        // marker before it can actually serve requests.
        try? "1".write(toFile: "\(dataDir)/daemon.ready", atomically: true, encoding: .utf8)

        // First-boot keyring init can take 2–3 minutes; run off the
        // main actor so the daemon stays responsive during the wait.
        Task.detached { await self.ensurePacmanKeyring() }

        // Set up immediate VM death notification via delegate callback
        vm.onVMStopped = { [weak self] in
            guard let self = self else { return }
            mslLog("VM died — shutting down daemon")
            self.shouldKeepRunning = false
            CFRunLoopStop(CFRunLoopGetMain())
        }

        while shouldKeepRunning {
            ensureDisplayBridge()
            // Use a short sleep so the daemon responds quickly to
            // stop/shutdown signals (instead of blocking for 30s).
            for _ in 0..<300 {
                if !shouldKeepRunning { break }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        mslLog("daemon shutting down")
    }

    private func ensurePacmanKeyring() async {
        let hostMarker = "\(dataDir)/.pacman-key.done"
        if FileManager.default.fileExists(atPath: hostMarker) { return }

        // Host-side lock prevents concurrent pacman-key runs across
        // daemon restarts / parallel invocations.  The guest also has a
        // systemd one-shot (msl-pacman-key.service) that runs the same
        // command — when both try pacman-key --init simultaneously they
        // corrupt each other's gnupg state.
        let lockPath = "\(dataDir)/.pacman-key.lock"
        let lockFD = open(lockPath, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        if lockFD < 0 { return }
        defer { close(lockFD) }
        // Non-blocking exclusive lock — if another process holds the lock,
        // skip (they will write the hostMarker when done).
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 { return }

        // Re-check guest marker under lock — another process may have
        // finished while we were waiting.
        let guestMarker = "/var/lib/msl-pacman-key.done"
        let (_, checkExit) = await vm.execOnGuest("test -f \(guestMarker)")
        if checkExit == 0 {
            try? "".write(toFile: hostMarker, atomically: true, encoding: .utf8)
            return
        }

        // Check if the guest's own systemd service is already running
        // pacman-key.  If so, wait for it to finish instead of duplicating.
        let (_, alreadyRunning) = await vm.execOnGuest("pgrep -x pacman-key >/dev/null 2>&1")
        if alreadyRunning == 0 {
            mslLog("pacman-key already running in guest — waiting up to 180s")
            for _ in 0..<180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let (_, done) = await vm.execOnGuest("test -f \(guestMarker)")
                if done == 0 {
                    try? "".write(toFile: hostMarker, atomically: true, encoding: .utf8)
                    return
                }
                let (_, stillRunning) = await vm.execOnGuest("pgrep -x pacman-key >/dev/null 2>&1")
                if stillRunning != 0 { break } // process finished but marker absent — fall through to run ourselves
            }
        }

        mslLog("initializing pacman keyring")
        let (out, code) = await vm.execOnGuest(pacmanKeySetupCommand, timeout: 180)
        if code == 0 { try? "".write(toFile: hostMarker, atomically: true, encoding: .utf8) }
        else { mslLog("pacman-key init failed (exit \(code)): \(String(data: out, encoding: .utf8) ?? "")") }
    }

    private func stopShellListener() {
        if shellListenerSock >= 0 {
            close(shellListenerSock)
            shellListenerSock = -1
        }
        unlink("\(dataDir)/msld.shell.sock")
    }

    private func startShellListener() {
        let shellPath = "\(dataDir)/msld.shell.sock"
        unlink(shellPath)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            mslLog("shell listener socket creation failed: \(String(cString: strerror(errno)))")
            return
        }
        shellListenerSock = sock
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { strncpy($0, shellPath, pathSize - 1) }
        let addrSize = MemoryLayout.size(ofValue: addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(addrSize)) }
        }
        guard bound == 0 else {
            mslLog("shell listener bind failed: \(String(cString: strerror(errno)))")
            close(sock)
            shellListenerSock = -1
            return
        }
        listen(sock, 8)
        chmod(shellPath, 0o600)

        DispatchQueue.global().async { [weak self] in
            while true {
                let client = accept(sock, nil, nil)
                guard client >= 0 else {
                    if errno != EINTR {
                        mslLog("shell accept failed: \(String(cString: strerror(errno))) — listener exiting")
                    }
                    break
                }
                self?.handleShellClient(client)
            }
        }
    }

    private func handleShellClient(_ client: Int32) {
        DispatchQueue.main.async { [self] in
            vm.connectVsock(port: 9999) { [self] result in
                switch result {
                case .success(let (handle, vsockFd)):
                    let cleanup = { DispatchQueue.main.async { self.vm.closeVsock(handle: handle) } }
                    DispatchQueue.global().async {
                        guard self.acquireSession() else {
                            close(client)
                            return
                        }
                        defer { self.releaseSession() }
                        if !writeMslToken(vsockFd) {
                            cleanup()
                            close(client)
                            return
                        }
                        var mode: UInt8 = 0x01
                        _ = write(vsockFd, &mode, 1)
                        var ok: UInt8 = 1
                        _ = write(client, &ok, 1)
                        let bufsize = 65536
                        var buf = [UInt8](repeating: 0, count: bufsize)
                        let cliFD = client, vsockFD = vsockFd

                        while true {
                            var pfds = [
                                pollfd(fd: cliFD, events: Int16(POLLIN), revents: 0),
                                pollfd(fd: vsockFD, events: Int16(POLLIN), revents: 0)
                            ]
                            var pret: Int32
                            repeat {
                                pret = poll(&pfds, 2, 100)
                            } while pret < 0 && errno == EINTR
                            if pret < 0 { break }

                            if pfds[0].revents & Int16(POLLIN) != 0 {
                                let (n, nErrno) = buf.withUnsafeMutableBytes { ptr -> (Int, Int32) in
                                    let bytesRead = read(cliFD, ptr.baseAddress!, ptr.count)
                                    return (bytesRead, errno)
                                }
                                if n > 0 {
                                    var pos = 0
                                    while pos < n {
                                        let w = buf.withUnsafeBytes { raw in
                                            write(vsockFD, raw.baseAddress! + pos, n - pos)
                                        }
                                        if w <= 0 { break }
                                        pos += w
                                    }
                                    if pos < n { break }
                                } else if n == 0 { break
                                } else if nErrno != EAGAIN && nErrno != EWOULDBLOCK { break }
                            }

                            if pfds[1].revents & Int16(POLLIN) != 0 {
                                let (vn, vnErrno) = buf.withUnsafeMutableBytes { ptr -> (Int, Int32) in
                                    let bytesRead = read(vsockFD, ptr.baseAddress!, ptr.count)
                                    return (bytesRead, errno)
                                }
                                if vn > 0 {
                                    var pos = 0
                                    while pos < vn {
                                        let w = buf.withUnsafeBytes { raw in
                                            write(cliFD, raw.baseAddress! + pos, vn - pos)
                                        }
                                        if w <= 0 { break }
                                        pos += w
                                    }
                                    if pos < vn { break }
                                } else if vn == 0 {  break
                                } else if vnErrno != EAGAIN && vnErrno != EWOULDBLOCK { break }
                            }
                        }
                        cleanup()
                        close(client)
                    }
                case .failure(_):
                    close(client)
                }
            }
        }
    }

    private func waitForGuest(timeout: Int) async throws {
        let deadline = Date(timeIntervalSinceNow: Double(timeout))
        var lastError: Error?
        var attempts = 0

        while Date() < deadline {
            do {
                let handle: UnsafeMutableRawPointer
                let fd: Int32
                (handle, fd) = try await {
                    let box = VsockConnectBox()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            let (h, f) = try await self.vm.connectVsock(port: 9999)
                            box.handle = h
                            box.fd = f
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 15_000_000_000)
                            throw MslError("connectVsock timed out")
                        }
                        try await group.next()!
                        group.cancelAll()
                    }
                    return (box.handle!, box.fd)
                }()
                defer { vm.closeVsock(handle: handle) }
                if !writeMslToken(fd) { throw MslError("token write failed") }

                // Set socket timeout so we don't block indefinitely
                var tv = timeval(tv_sec: 15, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

                var mode: UInt8 = 0x00
                var zero: UInt32 = 0
                write(fd, &mode, 1)
                write(fd, &zero, 4)
                var buf: UInt32 = 0
                let n = read(fd, &buf, 4)
                if n == 0 {
                    mslLog("guest connected after \(attempts * 2)s")
                    return
                }
                attempts += 1
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                lastError = error
                attempts += 1
                if attempts % 15 == 0 {
                    mslLog("waiting for guest... (\(attempts * 2)s)")
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        throw lastError ?? MslError("guest daemon not reachable after \(timeout)s")
    }

    private func killSocat() {
        guard gSocatPID > 0 else { return }
        kill(gSocatPID, SIGTERM)
        gSocatPID = 0
    }

    private func handleRequest(_ data: Data, send: @escaping (Data) -> Void) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else {
            sendError(send, message: "invalid request")
            sendDone(send)
            return
        }

        switch cmd {
        case "exec":
            guard let args = json["args"] as? String else {
                sendError(send, message: "missing args")
                sendDone(send)
                return
            }
            handleExec(command: args, send: send)

        case "stop":
            handleStop(send: send)

        case "status":
            handleStatus(send: send)

        default:
            sendError(send, message: "unknown command: \(cmd)")
            sendDone(send)
        }
    }

    private func handleExec(command: String, send: @escaping (Data) -> Void) {
        // Delegate to the shared exec implementation on MSLVM.
        // This avoids duplication and ensures a consistent timeout budget
        // across host and guest (120s on both sides).
        Task {
            guard acquireSession() else {
                sendError(send, message: "too many concurrent sessions")
                sendDone(send)
                return
            }
            defer { releaseSession() }
            let (output, exitCode) = await vm.execOnGuest(command, timeout: 120)
            if !output.isEmpty {
                self.sendOutput(send, data: output)
            }
            self.sendExitCode(send, code: exitCode)
            self.sendDone(send)
        }
    }

    private func handleStop(send: @escaping (Data) -> Void) {
        sendDone(send)
        // Attempt clean VM shutdown (10s timeout) so the guest filesystem
        // is in a consistent state. The main loop polls every 100ms, so
        // shouldKeepRunning=false below stops the daemon promptly.
        Task.detached {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.vm.stop() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch { }
            self.shouldKeepRunning = false
        }
    }

    private func handleStatus(send: @escaping (Data) -> Void) {
        let status: [String: Any] = ["status": "running", "pid": getpid()]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            sendOutput(send, data: data)
        }
        sendExitCode(send, code: 0)
        sendDone(send)
    }

    private func makeFrame(type: MessageType, payload: Data) -> Data {
        var typeBE = type.rawValue.bigEndian
        var lenBE = UInt32(payload.count).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &typeBE) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &lenBE) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func sendOutput(_ send: @escaping (Data) -> Void, data: Data) {
        send(makeFrame(type: .output, payload: data))
    }

    private func sendExitCode(_ send: @escaping (Data) -> Void, code: UInt32) {
        var codeBE = code.bigEndian
        let payload = withUnsafeBytes(of: &codeBE) { Data($0) }
        send(makeFrame(type: .exitCode, payload: payload))
    }

    private func sendError(_ send: @escaping (Data) -> Void, message: String) {
        let payload = message.data(using: .utf8) ?? Data()
        send(makeFrame(type: .error, payload: payload))
    }

    private func sendDone(_ send: @escaping (Data) -> Void) {
        send(makeFrame(type: .done, payload: Data()))
    }
}
