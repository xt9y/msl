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
    var n: Int
    repeat { n = withUnsafePointer(to: &marker) { write(sock, $0, 1) } }
    while n < 0 && errno == EINTR
    repeat { n = withUnsafeBytes(of: &rowsBE) { write(sock, $0.baseAddress!, 2) } }
    while n < 0 && errno == EINTR
    repeat { n = withUnsafeBytes(of: &colsBE) { write(sock, $0.baseAddress!, 2) } }
    while n < 0 && errno == EINTR
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
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { strncpy($0, "\(dataDir)/msld.shell.sock", pathSize - 1) }
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
        signal(SIGTERM) { _ in restoreTerminal(); exit(130) }
        signal(SIGINT) { _ in restoreTerminal(); exit(130) }
        signal(SIGHUP) { _ in restoreTerminal(); exit(129) }

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
    task.launchPath = exe
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

func main() {
    let args = CommandLine.arguments

    if args.count == 1 {
        print("msl — macOS Subsystem for Linux")
        print("Run 'msl help' for usage.")
        exit(0)
    }

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
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\
        <key>com.apple.security.virtualization</key><true/>\
        <key>com.apple.security.network.server</key><true/>\
        <key>com.apple.security.network.client</key><true/>\
        </dict></plist>
        """
        let tmp = "/tmp/msl-entitlements.plist"
        try? plist.write(toFile: tmp, atomically: true, encoding: .utf8)
        let cs = Process()
        cs.launchPath = "/usr/bin/codesign"
        cs.arguments = ["--entitlements", tmp, "--force", "--sign", "-", exe]
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
