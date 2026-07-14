import Foundation

let dataDir = setupDataDir()
var savedTermios = termios()

func runShell() {
    signal(SIGPIPE, SIG_IGN)
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { print("error: socket"); exit(1) }
    defer { close(sock) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { strncpy($0, "\(dataDir)/msld.shell.sock", pathSize - 1) }
    let addrSize = MemoryLayout.size(ofValue: addr)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(addrSize)) }
    }
    guard rc == 0 else { print("error: connect: \(String(cString: strerror(errno)))"); exit(1) }

    // Wait up to 30s for the OK byte from daemon
    var ok: UInt8 = 0
    var okReceived = false
    for _ in 0..<300 {
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        let pr = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) }
        if pr > 0 {
            let n = read(sock, &ok, 1)
            if n == 1 && ok == 1 { okReceived = true; break }
        }
    }
    guard okReceived else { print("error: shell handshake failed"); exit(1) }

    let isTTY = isatty(STDIN_FILENO) == 1
    if isTTY {
        tcgetattr(STDIN_FILENO, &savedTermios)
        var raw = savedTermios
        raw.c_iflag &= ~tcflag_t(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
        raw.c_cflag &= ~tcflag_t(CSIZE | PARENB)
        raw.c_cflag |= tcflag_t(CS8)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    var running = true
    var buf = [UInt8](repeating: 0, count: 65536)
    while running {
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        let r1 = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) }
        if r1 > 0 {
            let n = read(sock, &buf, buf.count)
            if n > 0 { _ = write(STDOUT_FILENO, buf, n) } else { running = false }
        } else if r1 < 0 { break }
        pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let r2 = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 100) }
        if r2 > 0 {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n > 0 {
                var written = 0
                while written < n {
                    let w = write(sock, UnsafeRawPointer(buf) + written, n - written)
                    if w <= 0 { running = false; break }
                    written += w
                }
            } else if n == 0 {
                shutdown(sock, SHUT_WR)
                var pfd2 = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
                while withUnsafeMutablePointer(to: &pfd2) { poll($0, 1, 1000) } > 0 {
                    let n2 = read(sock, &buf, buf.count)
                    if n2 <= 0 { break }
                    _ = write(STDOUT_FILENO, buf, n2)
                }
                running = false
            } else { running = false }
        } else if r2 < 0 { break }
    }
    if isTTY { tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios) }
}

func printUsage() {
    print("Usage: msl --start | --stop | --status | --exec <command> | --shell | --setup | --version")
    print()
    print("Options:")
    print("  --start              Start the VM daemon (auto-setup if needed)")
    print("  --exec <command>     Run a command in the VM")
    print("  --shell              Open an interactive shell in the VM")
    print("  --stop               Stop the VM")
    print("  --status             Check VM status")
    print("  --setup              Download and prepare the VM disk image")
    print("  --version            Print version info")
    print("  --help               Show this help")
}

func main() {
    let args = CommandLine.arguments

    if args.count == 1 {
        printUsage()
        exit(0)
    }

    switch args[1] {
    case "--help", "-h":
        printUsage()

    case "--version", "-v":
        print("msl \(MSLVersion)")
        print("macOS Subsystem for Linux")

    case "--setup":
        do {
            try ensureSetup()
        } catch {
            print("\(error.localizedDescription)")
            exit(1)
        }

    case "--start":
        if !isSetupComplete() {
            print("First-time setup required. Downloading Arch Linux ARM...")
            do {
                try ensureSetup()
            } catch {
                print("\(error.localizedDescription)")
                exit(1)
            }
        }

        let daemon = Daemon(dataDir: dataDir)
        DispatchQueue.main.async {
            Task {
                do {
                    try await daemon.run()
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        CFRunLoopRun()
        exit(0)

    case "--exec":
        guard args.count >= 3 else {
            print("Usage: msl --exec <command>")
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
            print("error: \(error.localizedDescription)")
            exit(1)
        }

    case "--shell":
        runShell()

    case "--stop":
        let client = IPCClient(path: "\(dataDir)/msld.sock")
        do {
            let req: [String: Any] = ["cmd": "stop"]
            let reqData = try JSONSerialization.data(withJSONObject: req)
            _ = try client.send(request: reqData)
            print("VM stopped")
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }

    case "--status":
        let state = DaemonState(dataDir: dataDir)
        if state.isRunning() {
            print("msld is running (pid \(state.readPID() ?? 0))")
        } else {
            print("msld is not running")
        }

    default:
        print("Unknown option: \(args[1])")
        print()
        printUsage()
        exit(1)
    }
}

main()
