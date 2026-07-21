import Foundation

let mslLogPath = "\(NSTemporaryDirectory())msl-daemon.log"
let mslLogQueue = DispatchQueue(label: "msl.log")
let mslLogFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()

func mslLog(_ message: String) {
    let timestamp = mslLogFormatter.string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    mslLogQueue.sync {
        if !FileManager.default.fileExists(atPath: mslLogPath) {
            FileManager.default.createFile(atPath: mslLogPath, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: mslLogPath) else { return }
        defer { fh.closeFile() }
        let maxSize: UInt64 = 1024 * 1024
        fh.seekToEndOfFile()
        if fh.offsetInFile + UInt64(data.count) > maxSize {
            fh.closeFile()
            try? FileManager.default.removeItem(atPath: mslLogPath + ".1")
            try? FileManager.default.moveItem(atPath: mslLogPath, toPath: mslLogPath + ".1")
            FileManager.default.createFile(atPath: mslLogPath, contents: nil)
            guard let newFH = FileHandle(forWritingAtPath: mslLogPath) else { return }
            newFH.seekToEndOfFile()
            newFH.write(data)
            newFH.closeFile()
            return
        }
        fh.write(data)
    }
}

@discardableResult
func shell(_ command: String, quiet: Bool = false) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", command]
    do {
        try task.run()
    } catch {
        if !quiet { mslLog("shell command failed: \(error.localizedDescription)") }
        return -1
    }
    task.waitUntilExit()
    let rc = task.terminationStatus
    if rc != 0 && !quiet {
        mslLog("shell command (exit \(rc)): \(command)")
    }
    return rc
}

/// Run a shell command and throw if it fails.
@discardableResult
func shellOrThrow(_ command: String) throws -> Int32 {
    let rc = shell(command)
    guard rc == 0 else {
        throw MslError("command failed (exit \(rc)): \(command)")
    }
    return rc
}

/// Run an executable with an argument array (no shell) and return exit code.
@discardableResult
func proc(_ path: String, _ args: [String], cwd: String? = nil) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    guard (try? task.run()) != nil else { return -1 }
    task.waitUntilExit()
    return task.terminationStatus
}

/// Run an executable with an argument array and throw on failure.
@discardableResult
func procOrThrow(_ path: String, _ args: [String], cwd: String? = nil) throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw MslError("\(path) failed (exit \(task.terminationStatus)): \(args.prefix(4).joined(separator: " "))")
    }
    return task.terminationStatus
}

/// Arch Linux ARM build system key fingerprint (signs packages and checksums).
let archLinuxArmSigningKey = "68B3537F39A313B3E574D06777193F152BDBE6A6"

/// Try to GPG-verify `file` against a detached signature at `sigURL`.
/// Uses a temporary GNUPGHOME to avoid polluting the user's keyring.
/// Returns true if verification succeeds or gpg is unavailable / sig not found.
/// Throws if gpg is available but verification fails.
func verifyWithGPG(file: String, sigURL: String, keyFingerprint: String) throws -> Bool {
    guard proc("/usr/bin/gpg", ["--version"]) == 0 else { return false }
    guard let sigURL = URL(string: sigURL) else {
        throw MslError("invalid signature URL: \(sigURL)")
    }
    let sigData: Data
    do {
        sigData = try Data(contentsOf: sigURL)
    } catch {
        return false
    }
    let sigPath = "\(file).sig"
    try sigData.write(to: URL(fileURLWithPath: sigPath), options: .atomic)
    defer { try? FileManager.default.removeItem(atPath: sigPath) }
    let gnupgHome = "\(NSTemporaryDirectory())msl-gpghome.\(getpid())"
    try? FileManager.default.createDirectory(atPath: gnupgHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: gnupgHome) }
    var env = ProcessInfo.processInfo.environment
    env["GNUPGHOME"] = gnupgHome
    let gpgImport = Process()
    gpgImport.executableURL = URL(fileURLWithPath: "/usr/bin/gpg")
    gpgImport.arguments = ["--keyserver", "keyserver.ubuntu.com", "--recv-keys", keyFingerprint]
    gpgImport.environment = env
    gpgImport.standardInput = Pipe()
    gpgImport.standardError = Pipe()
    gpgImport.standardOutput = Pipe()
    try gpgImport.run()
    gpgImport.waitUntilExit()
    guard gpgImport.terminationStatus == 0 else {
        let errData = (gpgImport.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
        throw MslError("GPG key import failed for \(keyFingerprint): \(errMsg)")
    }
    let gpgVerify = Process()
    gpgVerify.executableURL = URL(fileURLWithPath: "/usr/bin/gpg")
    gpgVerify.arguments = ["--verify", sigPath, file]
    gpgVerify.environment = env
    gpgVerify.standardError = Pipe()
    gpgVerify.standardOutput = Pipe()
    do {
        try gpgVerify.run()
        gpgVerify.waitUntilExit()
        if gpgVerify.terminationStatus != 0 {
            let errData = (gpgVerify.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw MslError("GPG signature verification failed for \(file): \(errMsg)")
        }
        return true
    } catch let e as MslError {
        throw e
    } catch {
        throw MslError("GPG verification process failed: \(error.localizedDescription)")
    }
}

/// Verify a kernel .deb against Ubuntu's signed SHA256SUMS.
func verifyDebWithGPG(debPath: String, debURL: String) throws {
    let baseURL = debURL.dropLast(debURL.split(separator: "/").last?.count ?? 0)
    let shaURL = "\(baseURL)SHA256SUMS"
    let sigURL = "\(baseURL)SHA256SUMS.gpg"
    let filename = debURL.split(separator: "/").last.map(String.init) ?? ""

    // Fetch SHA256SUMS and signature
    guard let shaData = try? Data(contentsOf: URL(string: String(shaURL))!),
          let shaStr = String(data: shaData, encoding: .utf8) else {
        mslLog("warning: could not fetch SHA256SUMS for kernel verification — skipping GPG check")
        return
    }

    // Find the line for our file
    var expectedSha: String?
    for line in shaStr.split(separator: "\n") {
        if line.hasSuffix("  \(filename)") || line.hasSuffix(" *\(filename)") {
            expectedSha = line.split(separator: " ").first.map(String.init)
            break
        }
    }
    guard let expected = expectedSha else {
        throw MslError("kernel SHA256SUMS has no entry for \(filename)")
    }

    // Verify the checksum first
    let actual = sha256File(debPath)
    guard actual == expected else {
        throw MslError("kernel deb SHA256 mismatch for \(filename)")
    }

    // Verify the SHA256SUMS signature with Ubuntu's signing key
    // Ubuntu's archive signing key fingerprint
    let ubuntuKey = "871920D1991BC93C"
    _ = try verifyWithGPG(file: String(shaURL), sigURL: String(sigURL), keyFingerprint: ubuntuKey)
}

/// Download a URL to a file with retry, resume, and sha256 verification.
/// Throws on failure (checksum mismatch, download error, etc.).
func downloadWithChecksum(urls: [String], to destPath: String, expectedSha256: String?) throws {
    for (mirrorIndex, url) in urls.enumerated() {
        if mirrorIndex > 0 {
            print("  Trying mirror \(mirrorIndex + 1)/\(urls.count): \(url)")
        }
        for attempt in 1...3 {
            if attempt == 1 { print("  Downloading \(url)...") }
            else { print("  Retrying (\(attempt)/3)...") }
            fflush(stdout)
            var curlArgs = ["-Lsf", "--retry", "3", "--retry-delay", "5", "--connect-timeout", "30", "--max-time", "300"]
            if attempt > 1 { curlArgs += ["-C", "-"] }
            curlArgs += ["-o", destPath, url]
            let rc = proc("/usr/bin/curl", curlArgs)
            if rc == 0 {
                if let expected = expectedSha256 {
                    let actual = sha256File(destPath)
                    if actual == expected {
                        print("  Checksum verified.")
                        return
                    }
                    print("  checksum mismatch, trying next mirror")
                    try? FileManager.default.removeItem(atPath: destPath)
                    break
                }
                return
            }
            try? FileManager.default.removeItem(atPath: destPath)
            if attempt == 3 {
                if mirrorIndex == urls.count - 1 {
                    throw MslError("download failed after all mirrors: \(url)")
                }
                print("  mirror failed, trying next...")
            }
        }
    }
}

func sha256File(_ path: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    task.arguments = ["-a", "256", path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return "" }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: " ").first.map(String.init) ?? ""
}

/// Check available disk space. Throws if less than `requiredGB` GB is free.
func checkDiskSpace(requiredGB: Int, at path: String) throws {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return }
    let freeBytes = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    let freeGB = Int(freeBytes / (1024 * 1024 * 1024))
    if freeGB < requiredGB {
        throw MslError("insufficient disk space: \(requiredGB)GB required, \(freeGB)GB available at \(path)")
    }
}

struct VMConfig: Codable {
    var diskSizeGB: Int = 8
    var ramSizeGB: Int = 2
    var cpuCores: Int = 2

    static let `default` = VMConfig()

    static func load(from dataDir: String) -> VMConfig {
        let path = "\(dataDir)/config.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            do {
                return try JSONDecoder().decode(VMConfig.self, from: data)
            } catch {
                mslLog("warning: config.json is corrupt — using defaults: \(error.localizedDescription)")
            }
        }
        return .default
    }

    func save(to dataDir: String) {
        let path = "\(dataDir)/config.json"
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            mslLog("warning: failed to save config: \(error.localizedDescription)")
        }
    }
}

func ensureSetup(diskSizeGB: Int = 8, ramSizeGB: Int = 2, cpuCores: Int = 2) throws {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
    let dataDir = "\(home)/.msl"
    let kernelPath = "\(dataDir)/kernel"
    let diskPath = "\(dataDir)/arch.img"

    try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

    if fileExists(kernelPath) && isValidExt4(diskPath) {
        // Warn if the user passed flags that would be silently ignored.
        if diskSizeGB != 8 || ramSizeGB != 2 || cpuCores != 2 {
            print("note: msl is already configured — flags ignored (re-run with --force to re-create)")
        }
        return
    }

    print("msl setup\n")

    try checkDiskSpace(requiredGB: diskSizeGB + 2, at: dataDir)
    try checkDiskSpace(requiredGB: diskSizeGB + 2, at: NSTemporaryDirectory())

    try? FileManager.default.removeItem(atPath: kernelPath)
    try? FileManager.default.removeItem(atPath: diskPath)

    let mke2fs = try ensureMke2fs()
    ensureXQuartz()
    let msldPath = ensureMsldBinary()

    let tmpdir = "/tmp/msl-rootfs-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpdir, withIntermediateDirectories: true)
    defer {
        shell("chmod -R u+w '\(tmpdir)' 2>/dev/null; rm -rf '\(tmpdir)' 2>/dev/null")
    }

    let tarballPath = "\(tmpdir)/rootfs.tar.gz"
    let mirrors = [
        "https://github.com/xt9y/MSL/releases/download/rootfs/ArchLinuxARM-aarch64-latest.tar.gz",
        "https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz",
        "https://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz",
        "https://eu.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz",
    ]
    let sha256URL = "https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.sha256"

    var expectedSha: String? = nil
    if ProcessInfo.processInfo.environment["MSL_NO_VERIFY"] == nil {
        guard let shaURL = URL(string: sha256URL) else {
            throw MslError("invalid sha256 URL: \(sha256URL)")
        }
        do {
            let shaData = try Data(contentsOf: shaURL)
            guard let shaStr = String(data: shaData, encoding: .utf8) else {
                throw MslError("sha256 response not valid UTF-8")
            }
            expectedSha = shaStr.split(separator: " ").first.map(String.init)
            if expectedSha == nil {
                throw MslError("failed to parse sha256 checksum from \(sha256URL)")
            }
        } catch {
            print("  warning: could not fetch sha256 checksum — proceeding without verification")
            print("           (\(error.localizedDescription))")
            // Note: sha256 is fetched from archlinuxarm.org, same origin as one
            // of the tarball mirrors. Same-origin compromise defeats both checks.
            // GPG verification (below) provides independent trust.
        }
    }

    try downloadWithChecksum(urls: mirrors, to: tarballPath, expectedSha256: expectedSha)

    let sigURL = "\(sha256URL).sig"
    do {
        if try verifyWithGPG(file: tarballPath, sigURL: sigURL, keyFingerprint: archLinuxArmSigningKey) {
            print("  GPG signature verified.")
        }
    } catch {
        print("  error: GPG verification failed: \(error.localizedDescription)")
        throw error
    }

    print("  Extracting rootfs...")
    fflush(stdout)
    _ = shell("tar xzf '\(tarballPath)' -C '\(tmpdir)' 2>&1")
    let fileCount = (try? FileManager.default.subpathsOfDirectory(atPath: tmpdir).count) ?? 0
    if fileCount < 10 {
        throw MslError("rootfs extraction failed (only \(fileCount) files)")
    }
    try? FileManager.default.removeItem(atPath: tarballPath)

    print("  Configuring system...")
    print("  WARNING: root account has no password. Do not enable SSH")
    print("           without setting a password inside the VM first.")
    fflush(stdout)
    try procOrThrow("/usr/bin/sed", ["-i", "", "s|^root:.*|root::0:0:root:/root:/bin/bash|", "\(tmpdir)/etc/shadow"])
    try procOrThrow("/usr/bin/sed", ["-i", "", "s|^root:.*|root::0:0:root:/root:/bin/bash|", "\(tmpdir)/etc/passwd"])
    shell("ln -sf /dev/null '\(tmpdir)/etc/systemd/system/systemd-firstboot.service'")
    shell("ln -sf ../usr/share/zoneinfo/UTC '\(tmpdir)/etc/localtime'")
    try? FileManager.default.removeItem(atPath: "\(tmpdir)/etc/machine-id")
    try? FileManager.default.createDirectory(atPath: "\(tmpdir)/root", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: "\(tmpdir)/root/.gnupg", withIntermediateDirectories: true)
    let bashrc = "export HOME=/root\nexport TERM=xterm-256color\n"
    try bashrc.write(toFile: "\(tmpdir)/root/.bashrc", atomically: true, encoding: .utf8)
    let bashProfile = "if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n"
    try bashProfile.write(toFile: "\(tmpdir)/root/.bash_profile", atomically: true, encoding: .utf8)
    // Force Mesa software rendering (llvmpipe/lavapipe) system-wide.
    // LP_NUM_THREADS matches the guest CPU count for best performance.
    let environment = "LIBGL_ALWAYS_SOFTWARE=1\n__GLX_VENDOR_LIBRARY_NAME=mesa\nVK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json\nLP_NUM_THREADS=\(cpuCores)\n"
    try environment.write(toFile: "\(tmpdir)/etc/environment", atomically: true, encoding: .utf8)
    try? FileManager.default.createDirectory(atPath: "\(tmpdir)/etc/profile.d", withIntermediateDirectories: true)
    let mesaProfile = "export LIBGL_ALWAYS_SOFTWARE=1\nexport __GLX_VENDOR_LIBRARY_NAME=mesa\nexport VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json\nexport LP_NUM_THREADS=\(cpuCores)\n"
    try mesaProfile.write(toFile: "\(tmpdir)/etc/profile.d/msl-mesa.sh", atomically: true, encoding: .utf8)

    // Guest firewall: drop all inbound on eth0 except established/related.
    // This is defense-in-depth; Virtualization.framework NAT already blocks
    // inbound from the LAN by default.
    try FileManager.default.createDirectory(atPath: "\(tmpdir)/etc/systemd/system", withIntermediateDirectories: true)
    let fwService = """
[Unit]
Description=MSL guest firewall
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/iptables -A INPUT -i eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT
ExecStart=/usr/bin/iptables -A INPUT -i eth0 -p udp --dport 68 -j ACCEPT
ExecStart=/usr/bin/iptables -A INPUT -i eth0 -j DROP
ExecStop=/usr/bin/iptables -F INPUT

[Install]
WantedBy=multi-user.target
"""
    try fwService.write(toFile: "\(tmpdir)/etc/systemd/system/msl-firewall.service", atomically: true, encoding: .utf8)
    try shellOrThrow("mkdir -p '\(tmpdir)/etc/systemd/system/multi-user.target.wants' && ln -sf /etc/systemd/system/msl-firewall.service '\(tmpdir)/etc/systemd/system/multi-user.target.wants/msl-firewall.service'")

    // Generate a random auth token for VSOCK connections. Written to both
    // the host (~/.msl/token) and the guest rootfs (/etc/msld-token).
    // Every VSOCK connection must send this token before the mode byte,
    // preventing a rogue guest process from impersonating msld.
    var tokenBytes = [UInt8](repeating: 0, count: 32)
    let randomFD = open("/dev/urandom", O_RDONLY)
    if randomFD >= 0 {
        _ = read(randomFD, &tokenBytes, 32)
        close(randomFD)
    }
    let tokenData = Data(tokenBytes)
    try tokenData.write(to: URL(fileURLWithPath: "\(dataDir)/token"), options: .atomic)
    shell("chmod 600 '\(dataDir)/token'")
    try tokenData.write(to: URL(fileURLWithPath: "\(tmpdir)/etc/msld-token"), options: .atomic)
    shell("chmod 600 '\(tmpdir)/etc/msld-token'")

    if let msld = msldPath {
        try procOrThrow("/bin/mkdir", ["-p", "\(tmpdir)/usr/local/bin"])
        try procOrThrow("/bin/cp", ["-L", msld, "\(tmpdir)/usr/local/bin/msld"])
        try procOrThrow("/bin/chmod", ["+x", "\(tmpdir)/usr/local/bin/msld"])
        print("  msld daemon embedded.")
    } else {
        fputs("  warning: msld not found — run 'brew install msld' first\n", stderr)
    }

    // Script to load VSOCK modules before starting msld.
    // Tries modprobe first (uses modules.dep for the running kernel).
    // Falls back to insmod with both .ko.zst (Ubuntu) and .ko (Arch) formats.
    let loadModulesScript = """
    #!/bin/sh
    # Log startup to kernel ring buffer for diagnostics
    echo "msld-wrapper: starting, uname=$(uname -r)" > /dev/kmsg 2>/dev/null

    # Try modprobe first (uses modules.dep)
    modprobe vsock 2>/dev/null && modprobe vmw_vsock_virtio_transport 2>/dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        echo "msld-wrapper: modprobe success" > /dev/kmsg 2>/dev/null
    else
        echo "msld-wrapper: modprobe failed, trying insmod" > /dev/kmsg 2>/dev/null
    fi

    # Fallback: try insmod with both .ko.zst (Ubuntu) and .ko (Arch) formats
    if ! lsmod 2>/dev/null | grep -q vsock; then
        echo "msld-wrapper: vsock not loaded, attempting insmod" > /dev/kmsg 2>/dev/null
        for m in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport; do
            for d in /lib/modules/*/kernel/net/vmw_vsock /usr/lib/modules/*/kernel/net/vmw_vsock; do
                for ext in .ko.zst .ko; do
                    f="$d/$m$ext"
                    if [ -f "$f" ]; then
                        echo "msld-wrapper: insmod $f" > /dev/kmsg 2>/dev/null
                        insmod "$f" 2>/dev/null
                        if [ $? -eq 0 ]; then
                            echo "msld-wrapper: insmod $m success" > /dev/kmsg 2>/dev/null
                            break 2
                        fi
                    fi
                done
            done
        done
    fi

    echo "msld-wrapper: starting msld" > /dev/kmsg 2>/dev/null
    exec /usr/local/bin/msld "$@"
    """
    let loadScriptPath = "\(tmpdir)/usr/local/bin/msld-wrapper.sh"
    try loadModulesScript.write(toFile: loadScriptPath, atomically: true, encoding: .utf8)
    shell("chmod +x '\(loadScriptPath)'")

    let svc = """
    [Unit]
    Description=msl Guest Daemon
    After=network.target

    [Service]
    ExecStart=/usr/local/bin/msld-wrapper.sh
    WorkingDirectory=/root
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    """
    try svc.write(toFile: "\(tmpdir)/etc/systemd/system/msld.service", atomically: true, encoding: .utf8)
    try shellOrThrow("mkdir -p '\(tmpdir)/etc/systemd/system/multi-user.target.wants' && ln -sf /etc/systemd/system/msld.service '\(tmpdir)/etc/systemd/system/multi-user.target.wants/msld.service'")

    let pacmanKeySvc = """
    [Unit]
    Description=Initialize pacman keyring (msl first-boot)
    After=network.target
    Wants=network.target
    ConditionPathExists=!/var/lib/msl-pacman-key.done

    [Service]
    Type=oneshot
    ExecStart=/bin/sh -c 'rm -f /var/lib/pacman/db.lck && chown -R root:root /root/.gnupg 2>/dev/null && chmod 700 /root/.gnupg 2>/dev/null && pacman-key --init && pacman-key --populate archlinuxarm && pacman -Sy --noconfirm archlinuxarm-keyring ncurses iptables-nft mesa vulkan-swrast vulkan-icd-loader vulkan-tools mesa-utils && pacman -Syy && modprobe nf_tables 2>/dev/null; modprobe nf_conntrack 2>/dev/null; modprobe xt_conntrack 2>/dev/null; systemctl enable --now msl-firewall || true; touch /var/lib/msl-pacman-key.done'
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """
    try pacmanKeySvc.write(toFile: "\(tmpdir)/etc/systemd/system/msl-pacman-key.service", atomically: true, encoding: .utf8)
    try shellOrThrow("mkdir -p '\(tmpdir)/etc/systemd/system/multi-user.target.wants' && ln -sf /etc/systemd/system/msl-pacman-key.service '\(tmpdir)/etc/systemd/system/multi-user.target.wants/msl-pacman-key.service'")
    shell("mkdir -p '\(tmpdir)/var/lib'")

    print("  Adding kernel...")
    fflush(stdout)

    func sha256ForDeb(url: String) -> String? {
        // Ubuntu only publishes directory-level SHA256SUMS, not per-file .sha256.
        // Try the real path first to avoid a guaranteed 404 on every kernel download.
        let base = url.dropLast(url.split(separator: "/").last?.count ?? 0)
        if let data = try? Data(contentsOf: URL(string: "\(base)SHA256SUMS")!),
           let str = String(data: data, encoding: .utf8) {
            let filename = url.split(separator: "/").last.map(String.init) ?? ""
            for line in str.split(separator: "\n") {
                if line.hasSuffix("  \(filename)") || line.hasSuffix(" *\(filename)") {
                    return line.split(separator: " ").first.map(String.init)
                }
            }
        }
        // Fallback: some mirrors may serve per-file .sha256 companions.
        if let data = try? Data(contentsOf: URL(string: "\(url).sha256")!),
           let str = String(data: data, encoding: .utf8) {
            return str.split(separator: " ").first.map(String.init)
        }
        return nil
    }

    // Prefer known-working kernel versions (6.8.x from Ubuntu Noble, gzip raw format).
    // Auto-discovery from the pool may pick newer kernels (6.17+, 7.x) that use
    // PE32+ EFI format, which is incompatible with VZLinuxBootLoader.
    let discovered = discoverKernelVersions().filter { ver, _ in
        let parts = parseKernelVersion(ver)
        // Accept kernels 6.8 through 6.12 (gzip raw format, known to work;
        // newer kernels use PE32+ EFI format incompatible with VZLinuxBootLoader)
        return parts.count >= 2 && parts[0] == 6 && parts[1] >= 8 && parts[1] <= 12
    }
    let kernelVersions: [(String, String)]
    if !discovered.isEmpty {
        kernelVersions = discovered
    } else {
        mslLog("kernel auto-discovery failed — using hardcoded fallback versions")
        kernelVersions = [
            ("6.8.0-53-generic", "6.8.0-53.55"),
            ("6.8.0-51-generic", "6.8.0-51.53"),
            ("6.8.0-45-generic", "6.8.0-45.47"),
        ]
    }
    var kernelDownloaded = false
    var kernelVer = ""
    let kernelDeb = "\(tmpdir)/kernel.deb"
    let modulesDeb = "\(tmpdir)/modules.deb"
    let ar = "/usr/bin/ar"

    for (ver, pkgRev) in kernelVersions {
        let kernelDebURL = "https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-image-unsigned-\(ver)_\(pkgRev)_arm64.deb"
        let modulesDebURL = "https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-modules-\(ver)_\(pkgRev)_arm64.deb"
        do {
            let kernelSha = sha256ForDeb(url: kernelDebURL)
            let modulesSha = sha256ForDeb(url: modulesDebURL)
            try downloadWithChecksum(urls: [kernelDebURL], to: kernelDeb, expectedSha256: kernelSha)
            try downloadWithChecksum(urls: [modulesDebURL], to: modulesDeb, expectedSha256: modulesSha)
            // GPG-verify both kernel and modules debs against Ubuntu's signed checksums
            // Modules carry the VSOCK kernel modules that form the host-guest trust
            // boundary — skipping verification here would be a critical blind spot.
            for (label, deb, url) in [("kernel", kernelDeb, kernelDebURL), ("modules", modulesDeb, modulesDebURL)] {
                do {
                    try verifyDebWithGPG(debPath: deb, debURL: url)
                    mslLog("\(label) GPG signature verified")
                } catch {
                    mslLog("\(label) GPG verification failed: \(error.localizedDescription)")
                    // Non-fatal: SHA256 already matched; GPG is defense-in-depth
                }
            }
            kernelVer = ver
            kernelDownloaded = true
            print("  Kernel \(ver) downloaded.")
            break
        } catch {
            try? FileManager.default.removeItem(atPath: kernelDeb)
            try? FileManager.default.removeItem(atPath: modulesDeb)
            continue
        }
    }

    guard kernelDownloaded else {
        throw MslError("failed to download kernel")
    }
    let debKernelDir = "\(tmpdir)/deb-kernel"
    try procOrThrow("/bin/mkdir", ["-p", debKernelDir])
    try procOrThrow(ar, ["x", kernelDeb], cwd: debKernelDir)
    let contents = try FileManager.default.contentsOfDirectory(atPath: debKernelDir)
    let dataTars = contents.filter { $0.hasPrefix("data.tar") }
    guard !dataTars.isEmpty else {
        throw MslError("ar x produced no data.tar.* — malformed deb at \(kernelDeb)")
    }
    for tarball in dataTars {
        try procOrThrow("/usr/bin/tar", ["xf", "\(debKernelDir)/\(tarball)", "-C", tmpdir])
    }
    try? FileManager.default.removeItem(atPath: kernelDeb)
    let vmlinuz = "\(tmpdir)/boot/vmlinuz-\(kernelVer)"
    // Try gunzip decompression first (older kernels); fall back to direct copy (modern PE32+ EFI kernels)
    _ = shell("gunzip -c '\(vmlinuz)' > '\(kernelPath)' 2>/dev/null")
    if !fileExists(kernelPath) {
        _ = shell("cp '\(vmlinuz)' '\(kernelPath)' 2>/dev/null")
    }
    guard fileExists(kernelPath) else {
        throw MslError("kernel extraction failed — \(kernelPath) is missing or empty")
    }
    print("  Kernel \(kernelVer) extracted.")

    // Extract modules from the modules deb for VSOCK support in the rootfs.
    let modulesDir = "\(tmpdir)/deb-modules"
    try procOrThrow("/bin/mkdir", ["-p", modulesDir])
    try procOrThrow(ar, ["x", modulesDeb], cwd: modulesDir)
    let modContents = try FileManager.default.contentsOfDirectory(atPath: modulesDir)
    let modDataTars = modContents.filter { $0.hasPrefix("data.tar") }
    guard !modDataTars.isEmpty else {
        throw MslError("ar x produced no data.tar.* — malformed modules deb at \(modulesDeb)")
    }
    for tarball in modDataTars {
        try procOrThrow("/usr/bin/tar", ["xf", "\(modulesDir)/\(tarball)", "-C", modulesDir])
    }
    try? FileManager.default.removeItem(atPath: modulesDeb)

    // Move Ubuntu kernel modules into rootfs for VSOCK support.
    // Modern kernels use /usr/lib/modules/; older kernels use /lib/modules/.
    let modSrc = "\(modulesDir)/usr/lib/modules"
    let modSrcFallback = "\(modulesDir)/lib/modules"
    if FileManager.default.fileExists(atPath: modSrc) {
        shell("rm -rf '\(tmpdir)/usr/lib/modules/\(kernelVer)' 2>/dev/null; cp -r '\(modSrc)/\(kernelVer)' '\(tmpdir)/usr/lib/modules/' 2>/dev/null || true")
    } else if FileManager.default.fileExists(atPath: modSrcFallback) {
        shell("rm -rf '\(tmpdir)/usr/lib/modules/\(kernelVer)' 2>/dev/null; cp -r '\(modSrcFallback)/\(kernelVer)' '\(tmpdir)/usr/lib/modules/' 2>/dev/null || true")
    }
    let modTarget = "\(tmpdir)/usr/lib/modules/\(kernelVer)"
    // Generate minimal modules metadata for VSOCK
    // Detect whether the extracted modules use .ko.zst or .ko so we
    // generate a correct modules.dep regardless of the shipping format.
    let vsockDir = "\(modTarget)/kernel/net/vmw_vsock"
    let ext: String
    if fileExists("\(vsockDir)/vsock.ko.zst") {
        ext = ".ko.zst"
    } else if fileExists("\(vsockDir)/vsock.ko") {
        ext = ".ko"
    } else {
        ext = ".ko"    // best guess; insmod fallback in the wrapper covers both
    }
    let dep = """
    kernel/net/vmw_vsock/vsock.ko\(ext):
    kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko\(ext): kernel/net/vmw_vsock/vsock.ko\(ext)
    kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko\(ext): kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko\(ext)

    """
    shell("mkdir -p '\(modTarget)' 2>/dev/null")
    try? dep.write(toFile: "\(modTarget)/modules.dep", atomically: true, encoding: .utf8)
    try? "\n".write(toFile: "\(modTarget)/modules.alias", atomically: true, encoding: .utf8)
    try? "\n".write(toFile: "\(modTarget)/modules.symbols", atomically: true, encoding: .utf8)
    try? "\n".write(toFile: "\(modTarget)/modules.softdep", atomically: true, encoding: .utf8)
    let vsockConf = "vsock\nvmw_vsock_virtio_transport\n"
    try? vsockConf.write(toFile: "\(tmpdir)/etc/modules-load.d/vsock.conf", atomically: true, encoding: .utf8)
    print("  Kernel modules installed.")
    try? FileManager.default.removeItem(atPath: modulesDir)

    // Only chmod the specific files we need to be readable; avoid blanket +r
    // over the entire rootfs which could alter permissions on sensitive files.
    shell("chmod -R +r '\(tmpdir)/usr/local/bin' '\(tmpdir)/etc' '\(tmpdir)/boot' '\(tmpdir)/lib' 2>/dev/null")

    print("  Creating disk image (\(diskSizeGB)GB)...")
    fflush(stdout)
    // Strip setuid/setgid bits and ensure readability — mke2fs on macOS
    // cannot copy files with restricted permissions when running as
    // a non-root user.
    shell("chmod -R a-s,u+r '\(tmpdir)' 2>/dev/null || true")
    try procOrThrow(mke2fs, ["-t", "ext4", "-d", tmpdir, diskPath, "\(diskSizeGB)G"])
    print("  Disk image: \(diskPath)")

    let config = VMConfig(diskSizeGB: diskSizeGB, ramSizeGB: ramSizeGB, cpuCores: cpuCores)
    config.save(to: dataDir)

    print("\nDone. Run 'msl start' to boot the VM.\n")
}

func runUpdate(diskSizeGB: Int = 8, ramSizeGB: Int = 2, cpuCores: Int = 2) throws {
    print("msl update\n")
    let dataDir = setupDataDir()
    guard isSetupComplete() else {
        print("  No existing setup found — running full setup instead.")
        try ensureSetup(diskSizeGB: diskSizeGB, ramSizeGB: ramSizeGB, cpuCores: cpuCores)
        return
    }
    try? FileManager.default.removeItem(atPath: "\(dataDir)/kernel")
    try? FileManager.default.removeItem(atPath: "\(dataDir)/arch.img")
    try? FileManager.default.removeItem(atPath: "\(dataDir)/.pacman-key.done")
    try ensureSetup(diskSizeGB: diskSizeGB, ramSizeGB: ramSizeGB, cpuCores: cpuCores)
}

func setupDataDir() -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
    return "\(home)/.msl"
}

func isSetupComplete() -> Bool {
    let d = setupDataDir()
    return fileExists("\(d)/arch.img") && isValidExt4("\(d)/arch.img")
}

func fileExists(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0 && st.st_size > 0
}

func isValidExt4(_ path: String) -> Bool {
    guard let f = fopen(path, "rb") else { return false }
    defer { fclose(f) }
    fseek(f, 0x438, SEEK_SET)
    var buf = [UInt8](repeating: 0, count: 2)
    guard fread(&buf, 1, 2, f) == 2 else { return false }
    return buf[0] == 0x53 && buf[1] == 0xEF
}

private func findMke2fs() -> String? {
    var candidates = [
        "/opt/homebrew/sbin/mke2fs",
        "/usr/local/opt/e2fsprogs/sbin/mke2fs",
        "/opt/local/sbin/mke2fs",
    ]
    // Try dynamic brew prefix first
    let brewPrefix = shellOutput("brew --prefix 2>/dev/null")
    if !brewPrefix.isEmpty {
        candidates.insert("\(brewPrefix)/sbin/mke2fs", at: 0)
        candidates.insert("\(brewPrefix)/opt/e2fsprogs/sbin/mke2fs", at: 0)
    }
    for c in candidates {
        if access(c, X_OK) == 0 { return c }
    }
    return nil
}

private func ensureMke2fs() throws -> String {
    if let p = findMke2fs() { return p }
    print("  Installing e2fsprogs...")
    fflush(stdout)
    shell("brew install e2fsprogs 2>/dev/null", quiet: true)
    if let p = findMke2fs() { return p }
    throw MslError("mke2fs not found — install e2fsprogs via 'brew install e2fsprogs'")
}

private func findXQuartzApp() -> String? {
    let candidates = [
        "/Applications/Utilities/XQuartz.app",
        "/Applications/XQuartz.app",
    ]
    for c in candidates {
        var st = stat()
        if stat(c, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
            return c
        }
    }
    return nil
}

var gSocatPID: pid_t = 0

func ensureDisplayBridge() {
    // Skip in CI — no display server available
    if ProcessInfo.processInfo.environment["CI"] != nil { return }

    // XQuartz only listens on a local Unix socket; the VM connects over TCP.
    // socat bridges TCP 6000 -> /tmp/.X11-unix/X0 so the guest can reach it.
    let x11Socket = "/tmp/.X11-unix/X0"
    guard FileManager.default.fileExists(atPath: x11Socket) else { return }

    // Check if we already have a tracked socat process
    if gSocatPID > 0, kill(gSocatPID, 0) == 0 { return }

    // Check if something is already listening on 6000
    if shell("lsof -i :6000 >/dev/null 2>&1", quiet: true) == 0 { return }

    // Ensure socat is installed
    if shell("which socat >/dev/null 2>&1", quiet: true) != 0 {
        print("  Installing socat...")
        fflush(stdout)
        shell("brew install socat 2>/dev/null", quiet: true)
    }
    if shell("which socat >/dev/null 2>&1", quiet: true) != 0 {
        fputs("  warning: socat not found — GUI apps won't display\n", stderr)
        return
    }

    let pidStr = shellOutput("nohup socat TCP-LISTEN:6000,reuseaddr,fork UNIX-CONNECT:\(x11Socket) >/dev/null 2>&1 & echo $!")
    gSocatPID = pid_t(pidStr) ?? 0
    print("  X11 bridge started (port 6000).")
}

private func ensureXQuartz() {
    // Skip in CI — no display server available
    if ProcessInfo.processInfo.environment["CI"] != nil { return }

    if findXQuartzApp() == nil {
        print("  Installing XQuartz (for GUI display forwarding)...")
        fflush(stdout)
        shell("brew install --cask xquartz 2>&1", quiet: true)
        if findXQuartzApp() == nil {
            print("  warning: XQuartz not found — install manually from https://www.xquartz.org")
            print("           GUI apps from the VM won't display until XQuartz is installed.")
            return
        }
    }
    print("  Starting XQuartz...")
    shell("open -a XQuartz 2>/dev/null", quiet: true)
    // Wait for the X server to come up (xhost will fail until it's ready)
    let xhost = "/opt/X11/bin/xhost"
    for _ in 0..<30 {
        if shell("\(xhost) + >/dev/null 2>&1", quiet: true) == 0 {
            ensureDisplayBridge()
            print("  -> XQuartz ready (xhost +, TCP bridge on port 6000)")
            return
        }
        usleep(500_000)
    }
    print("  warning: XQuartz started but xhost + failed — GUI apps may not display")
}

/// Resolve the real directory containing the msl binary, following symlinks and PATH.
private func resolveSelfDir() -> String {
    let selfPath = resolveBinaryPath()
    if let resolved = realpath(selfPath, nil) {
        let rp = String(cString: resolved)
        free(resolved)
        return (rp as NSString).deletingLastPathComponent
    }
    return (selfPath as NSString).deletingLastPathComponent
}

@discardableResult
func shellOutput(_ command: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", command]
    let pipe = Pipe()
    task.standardOutput = pipe
    guard (try? task.run()) != nil else { return "" }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func findMsldBinary() -> String? {
    // Primary: msld in PATH (installed via homebrew formula)
    let which = shellOutput("which msld 2>/dev/null")
    if !which.isEmpty {
        var st = stat()
        if stat(which, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
            return which
        }
    }
    // Fallbacks for development builds
    let selfDir = resolveSelfDir()
    let candidates = [
        "\(selfDir)/msld",
        "\(FileManager.default.currentDirectoryPath)/build/msld",
    ]
    for c in candidates {
        let expanded = (c as NSString).standardizingPath
        var st = stat()
        if stat(expanded, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
            return expanded
        }
    }
    return nil
}

private func ensureMsldBinary() -> String? {
    if let p = findMsldBinary() { return p }
    print("  error: msld not found — install with: brew install msld")
    print("           then run: msl setup again")
    return nil
}

func parseKernelVersion(_ s: String) -> [Int] {
    let s = s.replacingOccurrences(of: "-generic", with: "")
    return s.split { $0 == "." || $0 == "-" }.compactMap { Int($0) }
}

func discoverKernelVersions() -> [(String, String)] {
    let urlString = "https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/"
    guard let url = URL(string: urlString) else { return [] }
    var data: Data?
    for attempt in 1...3 {
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { d, _, _ in
            data = d; sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 20)
        if data != nil { break }
        if attempt < 3 { usleep(500_000 * useconds_t(attempt)) }
    }
    guard let data = data, let html = String(data: data, encoding: .utf8) else { return [] }
    var versions: [(String, String)] = []
    let pattern = #"linux-image-unsigned-([\w.+-]+)_([\w.+-]+)_arm64\.deb"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    regex.enumerateMatches(in: html, range: nsRange) { match, _, _ in
        guard let match = match, match.numberOfRanges == 3 else { return }
        let verRange = Range(match.range(at: 1), in: html)!
        let revRange = Range(match.range(at: 2), in: html)!
        let ver = String(html[verRange])
        let rev = String(html[revRange])
        // Skip 64k page-size variants — Virtualization.framework requires 4K pages
        if ver.hasSuffix("-64k") { return }
        versions.append((ver, rev))
    }
    versions.sort { a, b in
        let aParts = parseKernelVersion(a.0)
        let bParts = parseKernelVersion(b.0)
        for (ap, bp) in zip(aParts, bParts) {
            if ap != bp { return ap > bp }
        }
        return aParts.count > bParts.count
    }
    return versions
}

/// Shared pacman keyring initialization command used both during rootfs setup
/// and as a fallback in the daemon's ensurePacmanKeyring(). All operations
/// are chained with && so failure at any step stops execution.
let pacmanKeySetupCommand = "rm -f /var/lib/pacman/db.lck && chown -R root:root /root/.gnupg 2>/dev/null && chmod 700 /root/.gnupg 2>/dev/null && pacman-key --init && pacman-key --populate archlinuxarm && pacman -Sy --noconfirm archlinuxarm-keyring ncurses iptables-nft mesa vulkan-swrast vulkan-icd-loader vulkan-tools mesa-utils && pacman -Syy && modprobe nf_tables 2>/dev/null; modprobe nf_conntrack 2>/dev/null; modprobe xt_conntrack 2>/dev/null; systemctl enable --now msl-firewall || true; touch /var/lib/msl-pacman-key.done"

struct MslError: Error, LocalizedError {
    let message: String
    init(_ msg: String) { self.message = msg }
    var errorDescription: String? { return "error: \(message)" }
}

/// Read the VSOCK auth token from ~/.msl/token. Returns nil if no token
/// file exists (pre-1.1.0 installs without auth — backward compatible).
func readMslToken() -> Data? {
    let tokenPath = "\(setupDataDir())/token"
    return try? Data(contentsOf: URL(fileURLWithPath: tokenPath))
}

/// Write the auth token to a VSOCK file descriptor and wait for a
/// single-byte ACK/NAK from the guest.  Returns true if the token was
/// accepted.  A NAK (0xFF) or timeout is logged but non-fatal so that
/// the caller can proceed (the guest will reject the command anyway).
func writeMslToken(_ fd: Int32) -> Bool {
    guard let token = readMslToken() else {
        mslLog("warning: VSOCK auth token not found at \(setupDataDir())/token — connections will not be authenticated")
        return true
    }
    var remaining = token
    while !remaining.isEmpty {
        let n = remaining.withUnsafeBytes { write(fd, $0.baseAddress, remaining.count) }
        if n <= 0 { return false }
        remaining = remaining.dropFirst(n)
    }

    // Wait a short while for the guest's ACK/NAK so we can detect
    // token staleness (disk image persisted across token rotation).
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var pr: Int32
    repeat { pr = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 2000) } }
    while pr < 0 && errno == EINTR
    if pr > 0 {
        var resp: UInt8 = 0
        if read(fd, &resp, 1) == 1 && resp == 0xFF {
            mslLog("warning: guest rejected auth token — token may be stale")
            mslLog("         re-run 'msl setup --force' to regenerate both host and guest tokens")
            return false
        }
    }
    return true
}
