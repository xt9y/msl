import Foundation
import Virtualization

class Daemon {
    let vm: MSLVM
    var state: DaemonState
    let ipc: IPCServer
    let dataDir: String
    var shouldKeepRunning = true
    var sigSourceTerm: DispatchSourceSignal?
    var sigSourceInt: DispatchSourceSignal?

    init(dataDir: String) {
        signal(SIGPIPE, SIG_IGN)
        self.dataDir = dataDir
        self.vm = MSLVM(dataDir: dataDir)
        self.state = DaemonState(dataDir: dataDir)
        self.ipc = IPCServer(path: "\(dataDir)/msld.sock")
    }

    func requestStop() {
        mslLog("received shutdown signal")
        Task {
            do {
                try await vm.stop()
            } catch {
                mslLog("vm.stop error: \(error.localizedDescription)")
            }
            shouldKeepRunning = false
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func run() async throws {
        if state.isRunning() {
            throw MslError("daemon already running (pid \(state.readPID() ?? 0))")
        }

        // Signal-safe shutdown via DispatchSource (not raw signal handlers)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in self?.requestStop() }
        termSource.activate()
        sigSourceTerm = termSource

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in self?.requestStop() }
        intSource.activate()
        sigSourceInt = intSource

        try state.writePID()
        defer { state.removePID() }

        try? FileManager.default.removeItem(atPath: "\(dataDir)/vm.dead")
        ensureDisplayBridge()

        mslLog("booting VM")
        try vm.boot()

        do {
            try await vm.start()
        } catch {
            mslLog("vm.start failed: \(error.localizedDescription)")
            throw error
        }

        do {
            try await waitForGuest(timeout: 120)
        } catch {
            mslLog("waitForGuest failed: \(error.localizedDescription)")
            throw error
        }

        mslLog("VM ready")
        try? "1".write(toFile: "\(dataDir)/daemon.ready", atomically: true, encoding: .utf8)
        await ensurePacmanKeyring()

        try ipc.start { [weak self] requestData, send in
            self?.handleRequest(requestData, send: send)
        }

        startShellListener()

        while shouldKeepRunning {
            ensureDisplayBridge()
            try await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
        }

        mslLog("daemon shutting down")
    }

    private func ensurePacmanKeyring() async {
        let hostMarker = "\(dataDir)/.pacman-key.done"
        if FileManager.default.fileExists(atPath: hostMarker) { return }
        let guestMarker = "/var/lib/msl-pacman-key.done"
        let (_, checkExit) = await vm.execOnGuest("test -f \(guestMarker)")
        if checkExit == 0 {
            try? "".write(toFile: hostMarker, atomically: true, encoding: .utf8)
            return
        }
        mslLog("initializing pacman keyring")
        let setup = "rm -f /var/lib/pacman/db.lck && chown -R root:root /root/.gnupg 2>/dev/null; chmod 700 /root/.gnupg 2>/dev/null; pacman-key --init && pacman-key --populate archlinuxarm && pacman -Sy --noconfirm archlinuxarm-keyring ncurses iptables-nft; pacman -Syy && systemctl enable --now msl-firewall && touch \(guestMarker)"
        let (out, code) = await vm.execOnGuest(setup, timeout: 180)
        if code == 0 {
            try? "".write(toFile: hostMarker, atomically: true, encoding: .utf8)
        } else {
            mslLog("pacman-key init failed (exit \(code)): \(String(data: out, encoding: .utf8) ?? "")")
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
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { strncpy($0, shellPath, pathSize - 1) }
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
                    DispatchQueue.global().async { [self] in
                        if !writeMslToken(vsockFd) { close(client); return }
                        var mode: UInt8 = 0x01
                        _ = write(vsockFd, &mode, 1)
                        var ok: UInt8 = 1
                        _ = write(client, &ok, 1)
                        let bufsize = 65536
                        var buf = [UInt8](repeating: 0, count: bufsize)
                        let cliFD = client, vsockFD = vsockFd

                        _ = fcntl(cliFD, F_SETFL, fcntl(cliFD, F_GETFL, 0) | O_NONBLOCK)
                        _ = fcntl(vsockFD, F_SETFL, fcntl(vsockFD, F_GETFL, 0) | O_NONBLOCK)

                        while true {
                            let n = read(cliFD, &buf, bufsize)
                            let nErrno = errno
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
                            } else if n == 0 {
                                break
                            } else if nErrno != EAGAIN && nErrno != EWOULDBLOCK {
                                break
                            }

                            let vn = read(vsockFD, &buf, bufsize)
                            let vnErrno = errno
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
                            } else if vn == 0 {
                                break
                            } else if vnErrno != EAGAIN && vnErrno != EWOULDBLOCK {
                                break
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
                if !writeMslToken(fd) { throw MslError("token write failed") }
                var mode: UInt8 = 0x00
                var zero: UInt32 = 0
                write(fd, &mode, 1)
                write(fd, &zero, 4)
                var buf: UInt32 = 0
                let n = read(fd, &buf, 4)
                vm.closeVsock(handle: handle)
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
        vm.connectVsock(port: 9999) { [self] result in
            DispatchQueue.global().async { [self] in
                switch result {
                case .success(let (handle, fd)):
                    defer { DispatchQueue.main.async { self.vm.closeVsock(handle: handle) } }

                    if !writeMslToken(fd) {
                        self.sendError(send, message: "VSOCK auth token write failed")
                        self.sendDone(send)
                        return
                    }

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

                    let totalBudgetSeconds: Double = 30
                    let maxOutputBytes = 10 * 1024 * 1024
                    let deadline = Date().addingTimeInterval(totalBudgetSeconds)
                    var outBuf = [UInt8](repeating: 0, count: 65536)
                    var allOutput = Data()
                    var timedOut = false

                    let flags = fcntl(fd, F_GETFL, 0)
                    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                    commandLoop: while true {
                        let remaining = max(0.0, deadline.timeIntervalSinceNow)
                        if remaining <= 0 { timedOut = true; break commandLoop }
                        let n = read(fd, &outBuf, outBuf.count)
                        let savedErrno = errno
                        if n > 0 {
                            if allOutput.count < maxOutputBytes {
                                let room = maxOutputBytes - allOutput.count
                                allOutput.append(outBuf, count: min(n, room))
                                if allOutput.count >= maxOutputBytes { break commandLoop }
                            }
                        } else if n == 0 {
                            break
                        } else if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK {
                            usleep(10000)
                            continue
                        } else {
                            break
                        }
                    }

                    if timedOut {
                        if !allOutput.isEmpty {
                            self.sendOutput(send, data: allOutput)
                        }
                        self.sendExitCode(send, code: 255)
                        self.sendDone(send)
                        return
                    }

                    guard allOutput.count >= 4 else {
                        self.sendDone(send)
                        return
                    }
                    let exitOffset = allOutput.count - 4
                    let outputData: Data
                    if exitOffset > 0 {
                        outputData = allOutput.withUnsafeBytes { ptr in
                            Data(bytes: ptr.baseAddress!, count: exitOffset)
                        }
                    } else {
                        outputData = Data()
                    }
                    let exitCode = allOutput.withUnsafeBytes { ptr in
                        ptr.loadUnaligned(fromByteOffset: exitOffset, as: UInt32.self).bigEndian
                    }

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