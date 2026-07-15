import Foundation

let mslLogPath = "/tmp/msl-daemon.log"

func mslLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: mslLogPath) {
        // Keep log under ~1 MB — truncate to the last 512 KB if it grows too large.
        let maxSize: UInt64 = 1024 * 1024
        let keepSize: UInt64 = 512 * 1024
        let size = (try? FileManager.default.attributesOfItem(atPath: mslLogPath)[.size] as? UInt64) ?? 0
        if size + UInt64(data.count) > maxSize {
            fh.seekToEndOfFile()
            let offset = size > keepSize ? size - keepSize : 0
            fh.truncateFile(atOffset: offset)
        }
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    }
}

@discardableResult
func shell(_ command: String) -> Int32 {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]
    task.launch()
    task.waitUntilExit()
    return task.terminationStatus
}

/// Download a URL to a file with retry, resume, and sha256 verification.
/// Throws on failure (checksum mismatch, download error, etc.).
func downloadWithChecksum(urls: [String], to destPath: String, expectedSha256: String?) throws {
    for (mirrorIndex, url) in urls.enumerated() {
        if mirrorIndex > 0 {
            print("  Trying mirror \(mirrorIndex + 1)/\(urls.count): \(url)")
        }
        for attempt in 1...3 {
            if attempt == 1 {
                print("  Downloading \(url)...")
            } else {
                print("  Retrying (\(attempt)/3)...")
            }
            fflush(stdout)
            let resumeFlag = attempt > 1 ? "-C -" : ""
            let rc = shell("curl -Lsf --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 300 \(resumeFlag) -o '\(destPath)' '\(url)' 2>&1")
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
    task.launchPath = "/usr/bin/shasum"
    task.arguments = ["-a", "256", path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    task.launch()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: " ").first.map(String.init) ?? ""
}

/// Check available disk space. Throws if less than `requiredGB` GB is free.
func checkDiskSpace(requiredGB: Int) throws {
    var fs = statfs()
    guard statfs("/Users", &fs) == 0 else { return }
    let freeBytes = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    let freeGB = Int(freeBytes / (1024 * 1024 * 1024))
    if freeGB < requiredGB {
        throw MslError("insufficient disk space: \(requiredGB)GB required, \(freeGB)GB available")
    }
}

struct VMConfig: Codable {
    var diskSizeGB: Int = 8
    var ramSizeGB: Int = 2
    var cpuCores: Int = 2

    static let `default` = VMConfig()

    static func load(from dataDir: String) -> VMConfig {
        let path = "\(dataDir)/config.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let config = try? JSONDecoder().decode(VMConfig.self, from: data) {
            return config
        }
        return .default
    }

    func save(to dataDir: String) {
        let path = "\(dataDir)/config.json"
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

func ensureSetup(diskSizeGB: Int = 8, ramSizeGB: Int = 2, cpuCores: Int = 2) throws {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
    let dataDir = "\(home)/.msl"
    let kernelPath = "\(dataDir)/kernel"
    let diskPath = "\(dataDir)/arch.img"

    try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

    if fileExists(kernelPath) && isValidExt4(diskPath) { return }

    print("msl setup\n")

    try checkDiskSpace(requiredGB: diskSizeGB + 2)

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

    let expectedSha = (try? Data(contentsOf: URL(string: sha256URL)!))
        .flatMap { String(data: $0, encoding: .utf8) }
        .flatMap { $0.split(separator: " ").first.map(String.init) }
    if expectedSha == nil {
        fputs("  warning: could not fetch sha256 checksum — skipping integrity check\n", stderr)
    }

    try downloadWithChecksum(urls: mirrors, to: tarballPath, expectedSha256: expectedSha)

    print("  Extracting rootfs...")
    fflush(stdout)
    _ = shell("tar xzf '\(tarballPath)' -C '\(tmpdir)' 2>&1")
    let fileCount = (try? FileManager.default.subpathsOfDirectory(atPath: tmpdir).count) ?? 0
    if fileCount < 10 {
        throw MslError("rootfs extraction failed (only \(fileCount) files)")
    }
    try? FileManager.default.removeItem(atPath: tarballPath)

    print("  Configuring system...")
    fflush(stdout)
    // Root is intentionally passwordless for this local dev VM — the VM
    // runs on the host's Virtualization.framework with VSOCK-only access
    // (no network login). Users who want network SSH should set a password.
    shell("sed -i '' 's|^root:.*|root::0:0:root:/root:/bin/bash|' '\(tmpdir)/etc/shadow' 2>/dev/null")
    shell("sed -i '' 's|^root:.*|root::0:0:root:/root:/bin/bash|' '\(tmpdir)/etc/passwd' 2>/dev/null")
    shell("ln -sf /dev/null '\(tmpdir)/etc/systemd/system/systemd-firstboot.service'")
    shell("ln -sf ../usr/share/zoneinfo/UTC '\(tmpdir)/etc/localtime'")
    try? FileManager.default.removeItem(atPath: "\(tmpdir)/etc/machine-id")
    try? FileManager.default.createDirectory(atPath: "\(tmpdir)/root", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: "\(tmpdir)/root/.gnupg", withIntermediateDirectories: true)
    let bashrc = "export HOME=/root\nexport TERM=xterm-256color\n"
    try bashrc.write(toFile: "\(tmpdir)/root/.bashrc", atomically: true, encoding: .utf8)
    let bashProfile = "if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n"
    try bashProfile.write(toFile: "\(tmpdir)/root/.bash_profile", atomically: true, encoding: .utf8)

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
    try tokenData.write(to: URL(fileURLWithPath: "\(tmpdir)/etc/msld-token"), options: .atomic)
    shell("chmod 600 '\(tmpdir)/etc/msld-token'")

    if let msld = msldPath {
        shell("mkdir -p '\(tmpdir)/usr/local/bin' && cp -L '\(msld)' '\(tmpdir)/usr/local/bin/msld' && chmod +x '\(tmpdir)/usr/local/bin/msld'")
        print("  msld daemon embedded.")
    } else {
        fputs("  warning: msld not found — run 'brew install msld' first\n", stderr)
    }

    // Script to load VSOCK modules before starting msld
    let loadModulesScript = """
    #!/bin/sh
    # Load VSOCK kernel modules for msld
    modprobe vsock 2>/dev/null && modprobe vmw_vsock_virtio_transport 2>/dev/null
    # If modprobe fails (no modules.dep), try insmod directly
    if ! lsmod 2>/dev/null | grep -q vsock; then
        for m in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport; do
            for d in /lib/modules/*/kernel/net/vmw_vsock; do
                f="$d/$m.ko.zst"
                [ -f "$f" ] && insmod "$f" 2>/dev/null && break
            done
        done
    fi
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
    shell("mkdir -p '\(tmpdir)/etc/systemd/system/multi-user.target.wants' && ln -sf /etc/systemd/system/msld.service '\(tmpdir)/etc/systemd/system/multi-user.target.wants/msld.service'")

    let pacmanKeySvc = """
    [Unit]
    Description=Initialize pacman keyring (msl first-boot)
    After=local-fs.target
    ConditionPathExists=!/var/lib/msl-pacman-key.done

    [Service]
    Type=oneshot
    ExecStart=/bin/sh -c 'rm -f /var/lib/pacman/db.lck && chown -R root:root /root/.gnupg 2>/dev/null; chmod 700 /root/.gnupg 2>/dev/null; pacman-key --init && pacman-key --populate archlinuxarm && pacman -Sy --noconfirm archlinuxarm-keyring ncurses; pacman -Syy && touch /var/lib/msl-pacman-key.done'
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """
    try pacmanKeySvc.write(toFile: "\(tmpdir)/etc/systemd/system/msl-pacman-key.service", atomically: true, encoding: .utf8)
    shell("mkdir -p '\(tmpdir)/etc/systemd/system/multi-user.target.wants' && ln -sf /etc/systemd/system/msl-pacman-key.service '\(tmpdir)/etc/systemd/system/multi-user.target.wants/msl-pacman-key.service'")
    shell("mkdir -p '\(tmpdir)/var/lib'")

    print("  Adding kernel...")
    fflush(stdout)

    // Try multiple kernel versions — Ubuntu rotates point releases out of
    // the archive, so a single hardcoded version will silently break.
    // We first attempt to discover versions from the Ubuntu package index
    // (auto-discovery), then fall back to a hardcoded list.
    func sha256ForDeb(url: String) -> String? {
        // Try per-file checksum first
        if let data = try? Data(contentsOf: URL(string: "\(url).sha256")!),
           let str = String(data: data, encoding: .utf8) {
            return str.split(separator: " ").first.map(String.init)
        }
        // Fall back: fetch SHA256SUMS from parent directory
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
        return nil
    }

    let kernelVersions: [(String, String)]
    let discovered = discoverKernelVersions()
    if !discovered.isEmpty {
        kernelVersions = discovered
    } else {
        kernelVersions = [
            ("6.8.0-145-generic", "6.8.0-145.149"),
            ("6.8.0-141-generic", "6.8.0-141.144"),
            ("6.8.0-139-generic", "6.8.0-139.142"),
            ("6.8.0-136-generic", "6.8.0-136.136"),
            ("6.8.0-101-generic", "6.8.0-101.104"),
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

    if kernelDownloaded {
        shell("mkdir -p '\(tmpdir)/deb-kernel' && cd '\(tmpdir)/deb-kernel' && \(ar) x '\(kernelDeb)' 2>/dev/null && for f in data.tar*; do tar xf \"$f\" -C '\(tmpdir)' 2>/dev/null; done")
        try? FileManager.default.removeItem(atPath: kernelDeb)
        let vmlinuz = "\(tmpdir)/boot/vmlinuz-\(kernelVer)"
        _ = shell("gunzip -c '\(vmlinuz)' > '\(kernelPath)' 2>/dev/null")
        guard fileExists(kernelPath) else {
            throw MslError("kernel extraction failed — \(kernelPath) is missing or empty")
        }
        print("  Kernel \(kernelVer) extracted.")
    } else {
        fputs("  warning: VSOCK kernel unavailable, using Arch ARM fallback\n", stderr)
        try? FileManager.default.removeItem(atPath: kernelDeb)
        let kernelNames = ["/boot/Image", "/boot/vmlinuz-linux-aarch64", "/boot/vmlinuz-linux", "/boot/Image.gz"]
        var kernelSrc: String?
        for name in kernelNames {
            let full = "\(tmpdir)\(name)"
            var st = stat()
            if stat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { kernelSrc = name; break }
        }
        guard let kernel = kernelSrc else {
            throw MslError("no kernel found in rootfs /boot/")
        }
        shell("cp '\(tmpdir)\(kernel)' '\(kernelPath)' 2>/dev/null")
        print("  Kernel extracted from \(kernel).")
    }

    let vsockModules = kernelDownloaded
    if vsockModules {
        shell("mkdir -p '\(tmpdir)/deb-modules' && cd '\(tmpdir)/deb-modules' && \(ar) x '\(modulesDeb)' 2>/dev/null && for f in data.tar*; do tar xf \"$f\" -C '\(tmpdir)' 2>/dev/null; done")
        try? FileManager.default.removeItem(atPath: modulesDeb)
        // Module extraction creates /lib as a real directory, breaking
        // Arch ARM's merged-usr layout (/lib → usr/lib). Move modules
        // under /usr/lib and restore /lib as a symlink.
        shell("mkdir -p '\(tmpdir)/usr/lib/modules'")
        shell("cp -r '\(tmpdir)/lib/modules/'* '\(tmpdir)/usr/lib/modules/' 2>/dev/null || true")
        shell("rm -rf '\(tmpdir)/lib'")
        shell("ln -sf usr/lib '\(tmpdir)/lib'")
        // Remove non-VSOCK modules to save space
        shell("find '\(tmpdir)/usr/lib/modules' -type f -name '*.ko.xz' ! -name '*vsock*' ! -name '*virtio*' -delete 2>/dev/null")
        shell("find '\(tmpdir)/usr/lib/modules' -type f -name '*.ko' ! -name '*vsock*' ! -name '*virtio*' -delete 2>/dev/null")
        shell("find '\(tmpdir)/usr/lib/modules' -type f -name '*.ko.zst' ! -name '*vsock*' ! -name '*virtio*' -delete 2>/dev/null")
        // Depmod can't run on macOS, so generate minimal modules.dep for VSOCK
        let kver = kernelVer.isEmpty ? "6.8.0-136-generic" : kernelVer
        let dep = """
        kernel/net/vmw_vsock/vsock.ko.zst:
        kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko.zst: kernel/net/vmw_vsock/vsock.ko.zst
        kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko.zst: kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko.zst
        kernel/net/vmw_vsock/vsock.ko.zst
        kernel/drivers/vhost/vhost_vsock.ko.zst: kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko.zst kernel/net/vmw_vsock/vsock.ko.zst
        kernel/net/vmw_vsock/vsock_diag.ko.zst: kernel/net/vmw_vsock/vsock.ko.zst
        kernel/net/vmw_vsock/vsock_loopback.ko.zst: kernel/net/vmw_vsock/vsock.ko.zst
        kernel/drivers/net/vsockmon.ko.zst: kernel/net/vmw_vsock/vsock.ko.zst

        """
        try dep.write(toFile: "\(tmpdir)/usr/lib/modules/\(kver)/modules.dep", atomically: true, encoding: .utf8)
        // Also generate minimal modules.alias (empty is fine), modules.symbols, modules.softdep
        try "\n".write(toFile: "\(tmpdir)/usr/lib/modules/\(kver)/modules.alias", atomically: true, encoding: .utf8)
        try "\n".write(toFile: "\(tmpdir)/usr/lib/modules/\(kver)/modules.symbols", atomically: true, encoding: .utf8)
        try "\n".write(toFile: "\(tmpdir)/usr/lib/modules/\(kver)/modules.softdep", atomically: true, encoding: .utf8)
        try "0\n".write(toFile: "\(tmpdir)/usr/lib/modules/\(kver)/modules.dep.bin", atomically: true, encoding: .utf8)
        let conf = "vsock\nvmw_vsock_virtio_transport\n"
        try? conf.write(toFile: "\(tmpdir)/etc/modules-load.d/vsock.conf", atomically: true, encoding: .utf8)
        print("  Kernel modules installed.")
    }

    // Only chmod the specific files we need to be readable; avoid blanket +r
    // over the entire rootfs which could alter permissions on sensitive files.
    shell("chmod -R +r '\(tmpdir)/usr/local/bin' '\(tmpdir)/etc' '\(tmpdir)/boot' '\(tmpdir)/lib' 2>/dev/null")

    print("  Creating disk image (\(diskSizeGB)GB)...")
    fflush(stdout)
    let cmd = "'\(mke2fs)' -t ext4 -d '\(tmpdir)' '\(diskPath)' \(diskSizeGB)G 2>&1"
    guard shell(cmd) == 0 else {
        throw MslError("failed to create disk image")
    }
    print("  Disk image: \(diskPath)")

    let config = VMConfig(diskSizeGB: diskSizeGB, ramSizeGB: ramSizeGB, cpuCores: cpuCores)
    config.save(to: dataDir)

    print("\nDone. Run 'msl start' to boot the VM.\n")
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
    let candidates = [
        "/opt/homebrew/sbin/mke2fs",
        "/usr/local/opt/e2fsprogs/sbin/mke2fs",
        "/opt/local/sbin/mke2fs",
    ]
    for c in candidates {
        if access(c, X_OK) == 0 { return c }
    }
    var st = stat()
    if stat("/opt/homebrew/Cellar/e2fsprogs", &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "ls /opt/homebrew/Cellar/e2fsprogs/*/sbin/mke2fs 2>/dev/null | head -1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return path
        }
    }
    return nil
}

private func ensureMke2fs() throws -> String {
    if let p = findMke2fs() { return p }
    print("  Installing e2fsprogs...")
    fflush(stdout)
    shell("brew install e2fsprogs 2>/dev/null")
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

func ensureDisplayBridge() {
    // Skip in CI — no display server available
    if ProcessInfo.processInfo.environment["CI"] != nil { return }

    // XQuartz only listens on a local Unix socket; the VM connects over TCP.
    // socat bridges TCP 6000 -> /tmp/.X11-unix/X0 so the guest can reach it.
    let x11Socket = "/tmp/.X11-unix/X0"
    guard FileManager.default.fileExists(atPath: x11Socket) else { return }

    // Check if something is already listening on 6000
    if shell("lsof -i :6000 >/dev/null 2>&1") == 0 { return }

    // Ensure socat is installed
    if shell("which socat >/dev/null 2>&1") != 0 {
        print("  Installing socat...")
        fflush(stdout)
        shell("brew install socat 2>/dev/null")
    }
    if shell("which socat >/dev/null 2>&1") != 0 {
        fputs("  warning: socat not found — GUI apps won't display\n", stderr)
        return
    }

    shell("nohup socat TCP-LISTEN:6000,reuseaddr,fork UNIX-CONNECT:\(x11Socket) >/dev/null 2>&1 &")
    print("  X11 bridge started (port 6000).")
}

private func ensureXQuartz() {
    // Skip in CI — no display server available
    if ProcessInfo.processInfo.environment["CI"] != nil { return }

    if findXQuartzApp() == nil {
        print("  Installing XQuartz (for GUI display forwarding)...")
        fflush(stdout)
        shell("brew install --cask xquartz 2>&1")
        if findXQuartzApp() == nil {
            print("  warning: XQuartz not found — install manually from https://www.xquartz.org")
            print("           GUI apps from the VM won't display until XQuartz is installed.")
            return
        }
    }
    print("  Starting XQuartz...")
    shell("open -a XQuartz 2>/dev/null")
    // Wait for the X server to come up (xhost will fail until it's ready)
    let xhost = "/opt/X11/bin/xhost"
    for _ in 0..<30 {
        if shell("\(xhost) + >/dev/null 2>&1") == 0 {
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
    var st = stat()
    if lstat(selfPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
        if let resolved = try? URL(resolvingAliasFileAt: URL(fileURLWithPath: selfPath)) {
            return (resolved.path as NSString).deletingLastPathComponent
        }
    }
    return (selfPath as NSString).deletingLastPathComponent
}

@discardableResult
func shellOutput(_ command: String) -> String {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.launch()
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

/// Auto-discover available kernel versions from Ubuntu Ports index.
/// Falls back to empty array (uses hardcoded list) on any error.
func discoverKernelVersions() -> [(String, String)] {
    let url = "https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/"
    guard let data = try? Data(contentsOf: URL(string: url)!),
          let html = String(data: data, encoding: .utf8)
    else { return [] }

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
        versions.append((ver, rev))
    }
    // Sort by numeric build number descending (newest first) to try latest first.
    // Lexicographic sort on "6.8.0-141-generic" vs "6.8.0-99-generic" would
    // put 99 after 141 because '9' > '1'.
    versions.sort { a, b in
        let aNum = a.0.split(separator: "-").dropFirst().first.flatMap { Int($0) } ?? 0
        let bNum = b.0.split(separator: "-").dropFirst().first.flatMap { Int($0) } ?? 0
        return aNum > bNum
    }
    return versions
}

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

/// Write the auth token to a VSOCK file descriptor. Called before sending
/// the mode byte on every VSOCK connection.
func writeMslToken(_ fd: Int32) -> Bool {
    guard let token = readMslToken() else { return true }
    var remaining = token
    while !remaining.isEmpty {
        let n = remaining.withUnsafeBytes { write(fd, $0.baseAddress, remaining.count) }
        if n <= 0 { return false }
        remaining = remaining.dropFirst(n)
    }
    return true
}