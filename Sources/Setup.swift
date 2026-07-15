import Foundation

@discardableResult
func shell(_ command: String) -> Int32 {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]
    task.launch()
    task.waitUntilExit()
    return task.terminationStatus
}

func ensureSetup() throws {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
    let dataDir = "\(home)/.msl"
    let kernelPath = "\(dataDir)/kernel"
    let diskPath = "\(dataDir)/arch.img"

    try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

    if fileExists(kernelPath) && isValidExt4(diskPath) { return }

    print("msl first-time setup\n")

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
    let tarballURL = "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"

    print("  Downloading Arch Linux ARM (~1GB, may take a while)...")
    fflush(stdout)
    guard shell("curl -Lsf -o '\(tarballPath)' '\(tarballURL)' 2>&1") == 0 else {
        throw MslError("failed to download Arch Linux ARM tarball")
    }

    print("  Extracting rootfs...")
    fflush(stdout)
    let tarResult = shell("tar xzf '\(tarballPath)' -C '\(tmpdir)' 2>&1")
    print("  -> tar exit: \(tarResult)")
    // Verify we got actual files
    let fileCount = (try? FileManager.default.subpathsOfDirectory(atPath: tmpdir).count) ?? 0
    print("  -> \(fileCount) files extracted")
    try? FileManager.default.removeItem(atPath: tarballPath)

    print("  Configuring system...")
    shell("sed -i '' 's|^root:.*|root::0:0:root:/root:/bin/bash|' '\(tmpdir)/etc/shadow' 2>/dev/null")
    shell("sed -i '' 's|^root:.*|root::0:0:root:/root:/bin/bash|' '\(tmpdir)/etc/passwd' 2>/dev/null")
    shell("ln -sf /dev/null '\(tmpdir)/etc/systemd/system/systemd-firstboot.service'")
    shell("ln -sf ../usr/share/zoneinfo/UTC '\(tmpdir)/etc/localtime'")
    try? FileManager.default.removeItem(atPath: "\(tmpdir)/etc/machine-id")
    try? FileManager.default.createDirectory(atPath: "\(tmpdir)/root", withIntermediateDirectories: true)
    let bashrc = "export HOME=/root\nexport DISPLAY=:1\n"
    try bashrc.write(toFile: "\(tmpdir)/root/.bashrc", atomically: true, encoding: .utf8)

    if let msld = msldPath {
        try FileManager.default.copyItem(atPath: msld, toPath: "\(tmpdir)/usr/local/bin/msld")
        shell("chmod +x '\(tmpdir)/usr/local/bin/msld'")
        print("  -> msld daemon embedded")
    } else {
        print("  warning: msld binary not found, guest daemon won't be available")
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
    ExecStart=/bin/sh -c 'pacman-key --init && pacman-key --populate archlinuxarm && touch /var/lib/msl-pacman-key.done'
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """
    try pacmanKeySvc.write(toFile: "\(tmpdir)/etc/systemd/system/msl-pacman-key.service", atomically: true, encoding: .utf8)
    shell("mkdir -p '\(tmpdir)/etc/systemd/system/multi-user.target.wants' && ln -sf /etc/systemd/system/msl-pacman-key.service '\(tmpdir)/etc/systemd/system/multi-user.target.wants/msl-pacman-key.service'")
    shell("mkdir -p '\(tmpdir)/var/lib'")

    print("  Adding VSOCK kernel...")
    fflush(stdout)
    let kernelVer = "6.8.0-136-generic"
    let kernelDeb = "\(tmpdir)/kernel.deb"
    let modulesDeb = "\(tmpdir)/modules.deb"
    let ar = "/usr/bin/ar"
    let kernelDebURL = "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-image-unsigned-\(kernelVer)_6.8.0-136.136_arm64.deb"
    let modulesDebURL = "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-modules-\(kernelVer)_6.8.0-136.136_arm64.deb"
    if shell("curl -Lsf -o '\(kernelDeb)' '\(kernelDebURL)' 2>&1") == 0 {
        shell("mkdir -p '\(tmpdir)/deb-kernel' && cd '\(tmpdir)/deb-kernel' && \(ar) x '\(kernelDeb)' 2>/dev/null && for f in data.tar*; do tar xf \"$f\" -C '\(tmpdir)' 2>/dev/null; done")
        try? FileManager.default.removeItem(atPath: kernelDeb)
        let vmlinuz = "\(tmpdir)/boot/vmlinuz-\(kernelVer)"
        let rc = shell("gunzip -c '\(vmlinuz)' > '\(kernelPath)' 2>/dev/null && echo KERNEL_OK || echo KERNEL_FAIL")
        print("  -> Ubuntu \(kernelVer) kernel (\(rc))")
    } else {
        print("  warning: failed to download VSOCK kernel, falling back to Arch ARM kernel")
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
        print("  -> kernel extracted from \(kernel)")
    }

    let vsockModules = shell("curl -Lsf -o '\(modulesDeb)' '\(modulesDebURL)' 2>&1") == 0
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
        let kver = "6.8.0-136-generic"
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
        print("  -> VSOCK kernel modules installed")
    }

    shell("chmod -R +r '\(tmpdir)' 2>/dev/null")

    print("  Creating disk image (8GB)...")
    fflush(stdout)
    let cmd = "'\(mke2fs)' -t ext4 -d '\(tmpdir)' '\(diskPath)' 8G 2>&1"
    guard shell(cmd) == 0 else {
        throw MslError("failed to create disk image")
    }
    print("  -> \(diskPath)")

    print("\nSetup complete.\n")
}

let MSLVersion = "1.0.2"

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
    print("  Installing e2fsprogs (needed to create disk image)...")
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
    // XQuartz only listens on a local Unix socket; the VM connects over TCP.
    // socat bridges TCP 6000 -> /tmp/.X11-unix/X0 so the guest can reach it.
    let x11Socket = "/tmp/.X11-unix/X0"
    guard FileManager.default.fileExists(atPath: x11Socket) else { return }

    // Check if something is already listening on 6000
    if shell("lsof -i :6000 >/dev/null 2>&1") == 0 { return }

    // Ensure socat is installed
    if shell("which socat >/dev/null 2>&1") != 0 {
        print("  Installing socat (for X11 TCP bridge)...")
        fflush(stdout)
        shell("brew install socat 2>/dev/null")
    }
    if shell("which socat >/dev/null 2>&1") != 0 {
        print("  warning: socat not found — GUI apps won't display")
        return
    }

    shell("nohup socat TCP-LISTEN:6000,reuseaddr,fork UNIX-CONNECT:\(x11Socket) >/dev/null 2>&1 &")
    print("  -> X11 TCP bridge started (port 6000)")
}

private func ensureXQuartz() {
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
    var selfPath = CommandLine.arguments[0]
    if !selfPath.hasPrefix("/") {
        let which = shellOutput("which \(selfPath) 2>/dev/null")
        if !which.isEmpty { selfPath = which }
    }
    var st = stat()
    if lstat(selfPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
        if let resolved = try? Foundation.URL(resolvingAliasFileAt: URL(fileURLWithPath: selfPath)) {
            selfPath = resolved.path
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
    let selfDir = resolveSelfDir()
    let candidates = [
        "\(selfDir)/msld",
        "\(selfDir)/../Guest/msld",
        "\(selfDir)/../share/msl/msld",
        "\(FileManager.default.currentDirectoryPath)/Guest/msld",
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

/// Find msld locally, build it from source, or download a pre-built binary.
private func ensureMsldBinary() -> String? {
    if let p = findMsldBinary() { return p }

    // Try building from source if the cross-compiler is available
    if shell("which aarch64-linux-musl-gcc >/dev/null 2>&1") == 0 {
        print("  Building guest daemon (msld)...")
        fflush(stdout)
        let selfDir = resolveSelfDir()
        let outPath = "\(NSTemporaryDirectory())msld-\(UUID().uuidString)"
        let srcCandidates = [
            "\(selfDir)/../Guest/msld.c",
            "\(selfDir)/../share/msl/msld.c",
        ]
        for src in srcCandidates {
            let expanded = (src as NSString).standardizingPath
            if shell("aarch64-linux-musl-gcc -static -Os -s -o '\(outPath)' '\(expanded)' 2>&1") == 0 {
                print("  -> msld built")
                return outPath
            }
        }
    }

    // Download pre-built msld from GitHub releases
    print("  Downloading guest daemon (msld)...")
    fflush(stdout)
    let outPath = "\(NSTemporaryDirectory())msld-\(UUID().uuidString)"
    let url = "https://github.com/xt9y/msl/releases/download/v\(MSLVersion)/msld"
    let rc = shell("curl -Lsf -o '\(outPath)' '\(url)' 2>&1")
    if rc == 0 {
        var st = stat()
        if stat(outPath, &st) == 0, st.st_size > 1000 {
            print("  -> msld downloaded")
            return outPath
        }
    }

    print("  warning: could not obtain msld (build or download failed)")
    print("           to build from source: brew tap filosottile/musl-cross && brew install musl-cross --with-aarch64")
    print("           then run: msl --setup again")
    return nil
}

struct MslError: Error, LocalizedError {
    let message: String
    init(_ msg: String) { self.message = msg }
    var errorDescription: String? { return "error: \(message)" }
}
