import Foundation

class Daemon {
    let vm: MSLVM
    let state: DaemonState
    let ipc: IPCServer
    let dataDir: String
    var shouldKeepRunning = true

    init(dataDir: String) {
        signal(SIGPIPE, SIG_IGN)
        self.dataDir = dataDir
        self.vm = MSLVM(dataDir: dataDir)
        self.state = DaemonState(dataDir: dataDir)
        self.ipc = IPCServer(path: "\(dataDir)/msld.sock")
    }

    func run() async throws {
        if state.isRunning() {
            throw MslError("daemon already running (pid \(state.readPID() ?? 0))")
        }

        try state.writePID()
        defer { state.removePID() }

        ensureDisplayBridge()

        print("[1/5] Creating VM configuration...")
        fflush(stdout)
        try vm.boot()

        print("[2/5] Starting VM...")
        fflush(stdout)
        do {
            try await vm.start()
        } catch {
            print("vm.start failed: \(error.localizedDescription)")
            throw error
        }

        print("Waiting for guest daemon (VSOCK port 9999)...")
        do {
            try await waitForGuest(timeout: 120)
        } catch {
            print("waitForGuest failed: \(error.localizedDescription)")
            throw error
        }

        print("VM ready")

        // Ensure the pacman keyring is initialized before serving
        // so every fresh boot can run pacman without manual setup.
        await ensurePacmanKeyring()

        print("Listening on \(dataDir)/msld.sock")

        try ipc.start { [weak self] requestData, send in
            self?.handleRequest(requestData, send: send)
        }

        startShellListener()

        while shouldKeepRunning {
            ensureDisplayBridge()
            try await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
        }
    }

    private func ensurePacmanKeyring() async {
        let marker = "/var/lib/msl-pacman-key.done"
        let (checkOut, checkExit) = await vm.execOnGuest("test -f \(marker)")
        _ = checkOut
        if checkExit == 0 { return }
        print("Initializing pacman keyring (first-boot)...")
        fflush(stdout)
        let cmd = "rm -f /var/lib/pacman/db.lck && chown -R root:root /root/.gnupg 2>/dev/null; chmod 700 /root/.gnupg 2>/dev/null; pacman-key --init && pacman-key --populate archlinuxarm && pacman -Sy --noconfirm archlinuxarm-keyring ncurses; pacman -Syy && touch \(marker)"
        let (out, code) = await vm.execOnGuest(cmd, timeout: 180)
        if code == 0 {
            print("  -> pacman keyring ready")
        } else {
            print("warning: pacman-key init failed (exit \(code)): \(String(data: out, encoding: .utf8) ?? "")")
        }
    }

    private func startShellListener() {
        let shellPath = "\(dataDir)/msld.shell.sock"
        unlink(shellPath)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { strncpy($0, shellPath, pathSize - 1) }
        let addrSize = MemoryLayout.size(ofValue: addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(addrSize)) }
        }
        guard bound == 0 else { close(sock); return }
        listen(sock, 8)
        chmod(shellPath, 0o600)

        DispatchQueue.global().async {
            while true {
                let client = accept(sock, nil, nil)
                guard client >= 0 else { if errno == EINTR { continue }; break }
                self.handleShellClient(client)
            }
        }
    }

    private func handleShellClient(_ client: Int32) {
        DispatchQueue.main.async { [self] in
            vm.connectVsock(port: 9999) { [self] result in
                switch result {
                case .success(let (handle, vsockFd)):
                    // Move relay off the main queue so --exec / --stop / --status
                    // and VM delegate callbacks stay live while a shell is open.
                    DispatchQueue.global().async { [self] in
                        var mode: UInt8 = 0x01
                        _ = write(vsockFd, &mode, 1)
                        var ok: UInt8 = 1
                        _ = write(client, &ok, 1)
                        // Relay — poll each fd with short timeout
                        let bufsize = 65536
                        var buf = [UInt8](repeating: 0, count: bufsize)
                        let cliFD = client, vsockFD = vsockFd
                        while true {
                            var pfd = pollfd(fd: cliFD, events: Int16(POLLIN), revents: 0)
                            let pret = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) }
                            if pret < 0 { break }
                            if pret > 0 {
                                let n = read(cliFD, &buf, bufsize)
                                if n <= 0 { break }
                                var pos = 0
                                while pos < n {
                                    let w = write(vsockFD, UnsafeRawPointer(buf) + pos, n - pos)
                                    if w <= 0 { break }
                                    pos += w
                                }
                                if pos < n { break }
                            }
                            pfd = pollfd(fd: vsockFD, events: Int16(POLLIN), revents: 0)
                            let vret = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) }
                            if vret < 0 { break }
                            if vret > 0 {
                                let n = read(vsockFD, &buf, bufsize)
                                if n <= 0 { break }
                                var pos = 0
                                while pos < n {
                                    let w = write(cliFD, UnsafeRawPointer(buf) + pos, n - pos)
                                    if w <= 0 { break }
                                    pos += w
                                }
                                if pos < n { break }
                            }
                        }
                        DispatchQueue.main.async { [self] in
                            self.vm.closeVsock(handle: handle)
                        }
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
                let (handle, fd) = try await vm.connectVsock(port: 9999)
                var mode: UInt8 = 0x00
                var zero: UInt32 = 0
                write(fd, &mode, 1)
                write(fd, &zero, 4)
                var buf: UInt32 = 0
                let n = read(fd, &buf, 4)
                vm.closeVsock(handle: handle)
                if n == 0 {
                    print("  -> connected after \(attempts * 2)s"); fflush(stdout)
                    return
                }
                attempts += 1
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                lastError = error
                attempts += 1
                if attempts % 15 == 0 {
                    print("  waiting... (\(attempts * 2)s elapsed)"); fflush(stdout)
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        throw lastError ?? MslError("guest daemon not reachable after \(timeout)s")
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
        // connectVsock is invoked on the VZ queue (main). The blocking I/O
        // (write/read/poll) below must NOT run on main, otherwise a long
        // guest command freezes --stop / --status / VM delegate callbacks.
        // Hop to a background queue as soon as we have the fd.
        vm.connectVsock(port: 9999) { [self] result in
            DispatchQueue.global().async { [self] in
                switch result {
                case .success(let (handle, fd)):
                    defer { DispatchQueue.main.async { self.vm.closeVsock(handle: handle) } }

                    var reqData = Data()
                    reqData.append(contentsOf: [0x00])
                    var cmdLen = UInt32(command.utf8.count).bigEndian
                    withUnsafeBytes(of: &cmdLen) { reqData.append(contentsOf: $0) }
                    reqData.append(command.data(using: .utf8)!)
                    var written = 0
                    while written < reqData.count {
                        let n = write(fd, (reqData as NSData).bytes + written, reqData.count - written)
                        if n <= 0 { break }
                        written += n
                    }

                    // Read with a true wall-clock budget via poll, so a slow/dribbling
                    // guest cannot wedge this forever. 5 minutes is plenty for the
                    // longest expected command (e.g. pacman -Syu on first run).
                    let totalBudgetSeconds: Double = 300
                    let deadline = Date().addingTimeInterval(totalBudgetSeconds)
                    var outBuf = [UInt8](repeating: 0, count: 65536)
                    var allOutput = Data()
                    timedOut: while true {
                        let remaining = max(0.0, deadline.timeIntervalSinceNow)
                        if remaining <= 0 { break timedOut }
                        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        let pollMs = Int32(min(remaining, 0.1) * 1000)
                        let pret = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, pollMs) }
                        if pret < 0 { break }
                        if pret == 0 { continue }
                        let n = read(fd, &outBuf, outBuf.count)
                        if n > 0 {
                            allOutput.append(outBuf, count: n)
                        } else if n == 0 {
                            break
                        } else {
                            break
                        }
                    }

                    guard allOutput.count >= 4 else {
                        self.sendDone(send)
                        return
                    }
                    let exitOffset = allOutput.count - 4
                    let outputData = allOutput.subdata(in: 0..<exitOffset)
                    let exitBytes = [UInt8](allOutput[exitOffset..<allOutput.count])
                    let exitCode = UInt32(exitBytes[0]) << 24 | UInt32(exitBytes[1]) << 16 | UInt32(exitBytes[2]) << 8 | UInt32(exitBytes[3])

                    if !outputData.isEmpty {
                        self.sendOutput(send, data: outputData)
                    }
                    self.sendExitCode(send, code: exitCode)
                    self.sendDone(send)

                case .failure(let error):
                    self.sendError(send, message: error.localizedDescription)
                    self.sendDone(send)
                }
            }
        }
    }

    private func handleStop(send: @escaping (Data) -> Void) {
        Task {
            do {
                try await vm.stop()
                sendDone(send)
                shouldKeepRunning = false
            } catch {
                sendError(send, message: error.localizedDescription)
                sendDone(send)
            }
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
