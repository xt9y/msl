import Foundation
import Virtualization

let dataDir = setupDataDir()
var savedTermios = termios()
var needTerminalRestore = false
var shellWinsizeNeedsUpdate = false

func restoreTerminal() {
    if needTerminalRestore {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
        needTerminalRestore = false
    }
}

func getTerminalSize() -> (UInt16, UInt16) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        return (ws.ws_row, ws.ws_col)
    }
    return (24, 80)
}

func sendWinsize(sock: Int32) {
    let (rows, cols) = getTerminalSize()
    var marker: UInt8 = 0x02
    var rowsBE = rows.bigEndian
    var colsBE = cols.bigEndian
    // Each write() on a stream socket may send fewer bytes than
    // requested even without an error; loop until all bytes are sent.
    withUnsafePointer(to: &marker) { ptr in
        var remaining = 1
        while remaining > 0 {
            let n = write(sock, ptr.advanced(by: 1 - remaining), remaining)
            if n < 0 { if errno == EINTR { continue } else { break } }
            remaining -= n
        }
    }
    withUnsafeBytes(of: &rowsBE) { ptr in
        var remaining = 2
        while remaining > 0 {
            let n = write(sock, ptr.baseAddress!.advanced(by: 2 - remaining), remaining)
            if n < 0 { if errno == EINTR { continue } else { break } }
            remaining -= n
        }
    }
    withUnsafeBytes(of: &colsBE) { ptr in
        var remaining = 2
        while remaining > 0 {
            let n = write(sock, ptr.baseAddress!.advanced(by: 2 - remaining), remaining)
            if n < 0 { if errno == EINTR { continue } else { break } }
            remaining -= n
        }
    }
}

func runShell() {
    let state = DaemonState(dataDir: dataDir)
    guard state.isRunning() else {
        fputs("msl: daemon not running — start with 'msl start'\n", stderr)
        exit(1)
    }

    signal(SIGPIPE, SIG_IGN)
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { fputs("msl: socket error\n", stderr); exit(1) }
    defer { close(sock) }

    var addr = sockaddr_un()
    let sunPath = "\(dataDir)/msld.shell.sock"
    let pathMax = MemoryLayout.size(ofValue: addr.sun_path)
    guard sunPath.utf8.count < pathMax else {
        fputs("msl: shell socket path too long\n", stderr); exit(1)
    }
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { strncpy($0, sunPath, pathMax - 1) }
    let addrSize = MemoryLayout.size(ofValue: addr)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(addrSize)) }
    }
    if rc != 0 {
        fputs("msl: shell not ready yet — VM may still be booting\n", stderr)
        exit(1)
    }

    var ok: UInt8 = 0
    var okReceived = false
    for _ in 0..<300 {
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        var pr: Int32
        repeat { pr = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) } }
        while pr < 0 && errno == EINTR
        if pr > 0 {
            let n = read(sock, &ok, 1)
            if n == 1 && ok == 1 { okReceived = true; break }
        }
    }
    guard okReceived else { fputs("msl: shell handshake failed\n", stderr); exit(1) }

    let isTTY = isatty(STDIN_FILENO) == 1
    if isTTY {
        sendWinsize(sock: sock)
        tcgetattr(STDIN_FILENO, &savedTermios)
        var raw = savedTermios
        raw.c_iflag &= ~tcflag_t(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
        raw.c_cflag &= ~tcflag_t(CSIZE | PARENB)
        raw.c_cflag |= tcflag_t(CS8)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        needTerminalRestore = true
        signal(SIGTERM) { _ in restoreTerminal(); _exit(130) }
        signal(SIGINT) { _ in restoreTerminal(); _exit(130) }
        signal(SIGHUP) { _ in restoreTerminal(); _exit(129) }

        shellWinsizeNeedsUpdate = false
        signal(SIGWINCH, SIG_IGN)
        let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winchSource.setEventHandler { shellWinsizeNeedsUpdate = true }
        winchSource.activate()
    }

    var running = true
    var buf = [UInt8](repeating: 0, count: 65536)
    while running {
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        var r1: Int32
        repeat { r1 = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) } }
        while r1 < 0 && errno == EINTR
        if r1 > 0 {
            var n: Int
            repeat { n = read(sock, &buf, buf.count) }
            while n < 0 && errno == EINTR
            if n > 0 { _ = write(STDOUT_FILENO, buf, n) } else { running = false }
        } else if r1 < 0 { break }
        pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        var r2: Int32
        repeat { r2 = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) } }
        while r2 < 0 && errno == EINTR
        if r2 > 0 {
            var n: Int
            repeat { n = read(STDIN_FILENO, &buf, buf.count) }
            while n < 0 && errno == EINTR
            if n > 0 {
                var written = 0
                if shellWinsizeNeedsUpdate && isTTY {
                    shellWinsizeNeedsUpdate = false
                    sendWinsize(sock: sock)
                }
                while written < n {
                    let w = buf.withUnsafeBytes { raw in
                        write(sock, raw.baseAddress! + written, n - written)
                    }
                    if w < 0 {
                        if errno == EINTR { continue }
                        running = false; break
                    }
                    if w == 0 { running = false; break }
                    written += w
                }
            } else if n == 0 {
                shutdown(sock, SHUT_WR)
                var pfd2 = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
                var pr2: Int32
                repeat { pr2 = withUnsafeMutablePointer(to: &pfd2) { poll($0, 1, 1000) } }
                while pr2 < 0 && errno == EINTR
                while pr2 > 0 {
                    var n2: Int
                    repeat { n2 = read(sock, &buf, buf.count) }
                    while n2 < 0 && errno == EINTR
                    if n2 <= 0 { break }
                    _ = write(STDOUT_FILENO, buf, n2)
                    repeat { pr2 = withUnsafeMutablePointer(to: &pfd2) { poll($0, 1, 1000) } }
                    while pr2 < 0 && errno == EINTR
                }
                running = false
            } else { running = false }
        } else if r2 < 0 { break }
    }
    restoreTerminal()
}

func printHelp() {
    print("Usage: msl <command> [options]")
    print()
    print("Commands:")
    print("  start              Start the VM")
    print("  stop               Stop the VM")
    print("  status             Show VM status")
    print("  shell              Open an interactive shell")
    print("  exec <command>     Run a command in the VM")
    print("  setup              Download and prepare the VM disk image")
    print("  update             Re-download rootfs and rebuild disk image")
    print("  fix                Re-sign binary (restore virtualization entitlement)")
    print("  upgrade            Update msl and msld (runs brew update && brew upgrade)")
    print("  uninstall          Remove all msl data")
    print("  version            Show version")
    print("  help               Show this help")
    print()
    print("Setup options:")
    print("  --disk-size N    Disk image size in GB (default: 8)")
    print("  --ram-size  N    RAM size in GB (default: 2)")
    print("  --cpu-cores N    Number of vCPUs (default: 2)")
}

func parseSetupFlags(_ args: [String]) -> (Int, Int, Int) {
    var diskSize = 8, ramSize = 2, cpuCores = 2
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--disk-size":  if i + 1 < args.count, let v = Int(args[i + 1]) { diskSize = v; i += 1 }
        case "--ram-size":   if i + 1 < args.count, let v = Int(args[i + 1]) { ramSize = v; i += 1 }
        case "--cpu-cores":  if i + 1 < args.count, let v = Int(args[i + 1]) { cpuCores = v; i += 1 }
        default:             break
        }
        i += 1
    }
    return (diskSize, ramSize, cpuCores)
}

func resolveBinaryPath() -> String {
    let exe = CommandLine.arguments[0]
    if exe.hasPrefix("/") { return exe }
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    for dir in pathEnv.split(separator: ":").map(String.init) {
        let full = "\(dir)/\(exe)"
        if access(full, X_OK) == 0 { return full }
    }
    return exe
}

func startDaemonInBackground() {
    let exe = resolveBinaryPath()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: exe)
    task.arguments = ["--start-daemon"]
    task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    task.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
        try task.run()
    } catch {
        fputs("msl: failed to start daemon: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let childPID = task.processIdentifier
    let state = DaemonState(dataDir: dataDir)
    // Wait up to 5s for the child to write its PID file
    for _ in 0..<50 {
        if let pid = state.readPID(), pid == childPID { break }
        usleep(100_000)
    }
    guard let pid = state.readPID(), pid == childPID else {
        fputs("msl: daemon failed to start — check /tmp/msl-daemon.log\n", stderr)
        exit(1)
    }

    // Wait for VM to be actually reachable (up to 120s for first boot)
    let readyPath = "\(dataDir)/daemon.ready"
    var vmReady = false
    for _ in 0..<1200 {
        if FileManager.default.fileExists(atPath: readyPath) {
            try? FileManager.default.removeItem(atPath: readyPath)
            vmReady = true
            break
        }
        usleep(100_000)
    }
    if vmReady { print("msl \(MSLVersion) started (pid \(pid))") }
    else { fputs("msl: VM booting in background (pid \(pid)) — use 'msl shell' to connect\n", stderr) }
}

func parseVersion(_ s: String) -> [Int]? {
    let parts = s.split(separator: ".").compactMap { Int($0) }
    guard parts.count >= 2, parts.allSatisfy({ $0 >= 0 }) else { return nil }
    return parts
}

func compareVersions(_ a: [Int], _ b: [Int]) -> ComparisonResult {
    let count = max(a.count, b.count)
    for i in 0..<count {
        let va = i < a.count ? a[i] : 0
        let vb = i < b.count ? b[i] : 0
        if va < vb { return .orderedAscending }
        if va > vb { return .orderedDescending }
    }
    return .orderedSame
}

func checkForUpdate() {
    let cachePath = "\(dataDir)/.version-cache"
    let cacheTTL: TimeInterval = 3600
    let now = Date().timeIntervalSince1970

    var latestTag: String?
    if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
       let body = String(data: data, encoding: .utf8) {
        let lines = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        if lines.count == 2, let cachedAt = TimeInterval(lines[0]), now - cachedAt < cacheTTL {
            latestTag = String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    if latestTag == nil,
       let url = URL(string: "https://api.github.com/repos/xt9y/msl/tags") {
        let semaphore = DispatchSemaphore(value: 0)
        var apiData: Data?
        var apiError: Error?
        let task = URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { data, _, error in
            apiData = data
            apiError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        if let data = apiData,
           let tags = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let verTags = tags.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.hasPrefix("v") }
            let latest = verTags.max { a, b in
                guard let pa = parseVersion(String(a.dropFirst())),
                      let pb = parseVersion(String(b.dropFirst())) else {
                    return false
                }
                return compareVersions(pa, pb) == .orderedAscending
            }
            if let tag = latest {
                latestTag = tag
                try? "\(now)\n\(tag)".write(toFile: cachePath, atomically: true, encoding: .utf8)
            }
        }
        if let err = apiError {
            mslLog("update check failed: \(err.localizedDescription)")
        }
    }

    guard let tag = latestTag, tag.hasPrefix("v") else { return }
    // Also skip the check if the local version is the dev placeholder
    // or if the tag can't be parsed (e.g. pre-release suffixes).
    guard MSLVersion != "0.0.0-dev",
          let curParts = parseVersion(MSLVersion),
          let tagParts = parseVersion(String(tag.dropFirst())) else { return }
    if compareVersions(tagParts, curParts) == .orderedDescending {
        fputs("msl: new version \(tag) available — run 'msl upgrade'\n", stderr)
    }
}

func main() {
    let args = CommandLine.arguments

    if args.count == 1 {
        print("msl — macOS Subsystem for Linux")
        print("Run 'msl help' for usage.")
        exit(0)
    }
    checkForUpdate()

    switch args[1] {
    case "help":
        printHelp()

    case "version":
        print("msl \(MSLVersion)")

    case "setup":
        let (ds, rs, cc) = parseSetupFlags(args)
        do {
            try ensureSetup(diskSizeGB: ds, ramSizeGB: rs, cpuCores: cc)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            mslLog("setup failed: \(error.localizedDescription)")
            exit(1)
        }

    case "update":
        let (ds, rs, cc) = parseSetupFlags(args)
        do {
            try runUpdate(diskSizeGB: ds, ramSizeGB: rs, cpuCores: cc)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "start":
        if !isSetupComplete() {
            let (ds, rs, cc) = parseSetupFlags(args)
            do {
                try ensureSetup(diskSizeGB: ds, ramSizeGB: rs, cpuCores: cc)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        let state = DaemonState(dataDir: dataDir)
        if state.isRunning() {
            print("msl is already running (pid \(state.readPID() ?? 0))")
            exit(0)
        }
        startDaemonInBackground()

    case "--start-daemon":
        let daemon = Daemon(dataDir: dataDir)
        DispatchQueue.main.async {
            Task {
                do {
                    try await daemon.run()
                } catch {
                    mslLog("daemon error: \(error.localizedDescription)")
                }
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        CFRunLoopRun()
        exit(0)

    case "exec":
        guard args.count >= 3 else {
            fputs("Usage: msl exec <command>\n", stderr)
            exit(1)
        }
        // Note: args are re-joined with spaces, then passed to guest /bin/sh -c.
        // The user's shell already parsed quoting, and the guest shell re-parses the
        // rejoined string. This means globs, $VARS, and embedded quotes may behave
        // unintuitively. For complex commands, wrap everything in single quotes:
        //   msl exec 'echo $HOME && ls -la'
        let command = args[2...].joined(separator: " ")
        let client = IPCClient(path: "\(dataDir)/msld.sock")
        do {
            let req: [String: Any] = ["cmd": "exec", "args": command]
            let reqData = try JSONSerialization.data(withJSONObject: req)
            let messages = try client.send(request: reqData)
            var exitCode: UInt32 = 255
            for msg in messages {
                switch msg.type {
                case .output:
                    FileHandle.standardOutput.write(msg.data)
                case .exitCode:
                    if msg.data.count >= 4 {
                        let bytes = [UInt8](msg.data[0..<4])
                        exitCode = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                    }
                case .error:
                    FileHandle.standardError.write(msg.data)
                case .done:
                    break
                }
            }
            exit(Int32(exitCode))
        } catch {
            fputs("msl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "shell":
        runShell()

    case "stop":
        let client = IPCClient(path: "\(dataDir)/msld.sock")
        do {
            let req: [String: Any] = ["cmd": "stop"]
            let reqData = try JSONSerialization.data(withJSONObject: req)
            _ = try client.send(request: reqData)
        } catch {
            fputs("msl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "status":
        let state = DaemonState(dataDir: dataDir)
        if state.isRunning() {
            print("running (pid \(state.readPID() ?? 0))")
        } else {
            print("stopped")
        }

    case "uninstall":
        let d = setupDataDir()
        do {
            try FileManager.default.removeItem(atPath: d)
            print("Removed \(d)")
            print("Run 'brew uninstall msl msld' to remove the binaries.")
        } catch {
            fputs("msl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "fix":
        let exe = resolveBinaryPath()
        // Read the canonical entitlements file bundled with the binary
        // instead of duplicating the plist content inline.
        let plist: String
        let bundled = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/msl.entitlements")
        if let data = try? Data(contentsOf: bundled),
           let str = String(data: data, encoding: .utf8) {
            plist = str
        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: "/usr/local/share/msl/msl.entitlements")),
                  let str = String(data: data, encoding: .utf8) {
            plist = str
        } else {
            fputs("msl: cannot find msl.entitlements — reinstall with 'brew reinstall msl'\n", stderr)
            exit(1)
        }
        // Detect the current signing identity so we preserve it rather
        // than unconditionally replacing a Developer ID signature with
        // ad-hoc (which would break Gatekeeper / notarization status).
        let currentIdentity: String
        let diag = Process()
        diag.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        diag.arguments = ["-d", "-v", exe]
        let diagOut = Pipe()
        diag.standardOutput = diagOut
        diag.standardError = FileHandle(forWritingAtPath: "/dev/null")
        if (try? diag.run()) != nil {
            diag.waitUntilExit()
            if diag.terminationStatus == 0 {
                let data = diagOut.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                // Lines starting with "Authority=" carry the identity name
                // we need to pass back to codesign -s.  Ad-hoc binaries
                // print "Signature=adhoc" with no Authority line.
                if let authLine = out.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }) {
                    currentIdentity = String(authLine.dropFirst("Authority=".count))
                } else {
                    currentIdentity = "-"
                }
            } else {
                currentIdentity = "-"
            }
        } else {
            currentIdentity = "-"
        }

        let tmp = "/tmp/msl-entitlements.plist"
        try? plist.write(toFile: tmp, atomically: true, encoding: .utf8)
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--entitlements", tmp, "--force", "--sign", currentIdentity, exe]
        cs.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        cs.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try cs.run()
            cs.waitUntilExit()
        } catch {
            fputs("msl: codesign failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        try? FileManager.default.removeItem(atPath: tmp)
        guard cs.terminationStatus == 0 else {
            fputs("msl: codesign failed (exit \(cs.terminationStatus))\n", stderr)
            exit(1)
        }
        if VZVirtualMachine.isSupported {
            print("msl: virtualization entitlement restored — restart daemon with 'msl start'")
        } else {
            fputs("msl: virtualization entitlement still missing — try 'brew reinstall msl'\n", stderr)
            exit(1)
        }

    case "upgrade":
        let brew = Process()
        brew.executableURL = URL(fileURLWithPath: "/bin/bash")
        brew.arguments = ["-c", "brew update && brew upgrade msl msld"]
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_INTERACTIVE"] = "1"
        brew.environment = env
        brew.standardOutput = FileHandle.standardOutput
        brew.standardError = FileHandle.standardError
        do {
            try brew.run()
            brew.waitUntilExit()
        } catch {
            fputs("msl: upgrade failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(brew.terminationStatus)

    case "check-virt":
        if VZVirtualMachine.isSupported {
            print("virtualization supported")
            exit(0)
        } else {
            print("virtualization not supported")
            exit(1)
        }

    default:
        fputs("msl: unknown command '\(args[1])'\n", stderr)
        fputs("Run 'msl help' for usage.\n", stderr)
        exit(1)
    }
}

main()
