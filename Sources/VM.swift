import Foundation
@preconcurrency import Virtualization

// MARK: - Unchecked sendable wrappers for Virtualization framework types

private struct UncheckedVM: @unchecked Sendable {
    let value: VZVirtualMachine
    init(_ vm: VZVirtualMachine) { self.value = vm }
}

class MSLVM: NSObject, @unchecked Sendable {
    let dataDir: String
    let kernelPath: String
    let diskPath: String

    var vm: VZVirtualMachine?
    var vsock: MSLVSOCK?

    /// Tracks whether vm.start() has resolved, so we can log if it
    /// resolves after the caller has already handled a timeout.
    private var startResolved = false
    var onVMStopped: (() -> Void)?

    init(dataDir: String) {
        self.dataDir = dataDir
        self.kernelPath = "\(dataDir)/kernel"
        self.diskPath = "\(dataDir)/arch.img"
    }

    private func loadOrCreateMachineIdentifier() -> VZGenericMachineIdentifier {
        let idPath = "\(dataDir)/machine-id"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: idPath)),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZGenericMachineIdentifier()
        try? id.dataRepresentation.write(to: URL(fileURLWithPath: idPath), options: .atomic)
        return id
    }

    func boot() throws {
        let kernelURL = URL(fileURLWithPath: kernelPath)
        let diskURL = URL(fileURLWithPath: diskPath)

        guard FileManager.default.fileExists(atPath: kernelPath) else {
            throw MslError("kernel not found at \(kernelPath)")
        }
        guard FileManager.default.fileExists(atPath: diskPath) else {
            throw MslError("disk image not found at \(diskPath)")
        }

        guard VZVirtualMachine.isSupported else {
            throw MslError("virtualization not supported on this Mac")
        }

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw init=/usr/lib/systemd/systemd"

        let disk: VZDiskImageStorageDeviceAttachment
        do {
            disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        } catch {
            throw MslError("failed to open disk image: \(error.localizedDescription)")
        }
        let storage = VZVirtioBlockDeviceConfiguration(attachment: disk)

        let config = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = loadOrCreateMachineIdentifier()
        config.platform = platform
        config.bootLoader = bootLoader
        let vmConfig = VMConfig.load(from: dataDir)
        config.cpuCount = vmConfig.cpuCores
        config.memorySize = UInt64(vmConfig.ramSizeGB) * 1024 * 1024 * 1024
        config.storageDevices = [storage]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        vsock = MSLVSOCK(configuration: config)

        let serialPath = "\(NSTemporaryDirectory())msl-serial.log"
        // Create or append — never truncate, so crash logs survive restarts.
        let serialFD = Darwin.open(serialPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let serialFH: FileHandle
        if serialFD >= 0 {
            serialFH = FileHandle(fileDescriptor: serialFD, closeOnDealloc: true)
        } else {
            serialFH = .standardError
        }
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: serialFH
        )
        config.serialPorts = [serialPort]

        do { try config.validate() }
        catch { throw MslError("config invalid: \(error.localizedDescription)") }

        vm = VZVirtualMachine(configuration: config, queue: .main)
        vm?.delegate = self

        if let v = vm { vsock?.setVM(v) }
    }

    func start() async throws {
        guard let vm = vm else { throw MslError("VM not configured") }
        let uncheckedVM = UncheckedVM(vm)
        startResolved = false

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.main.async {
                        uncheckedVM.value.start { result in
                            if self.startResolved {
                                mslLog("VM start completed after timeout — ignoring late result")
                                return
                            }
                            self.startResolved = true
                            switch result {
                            case .success: cont.resume()
                            case .failure(let err): cont.resume(throwing: err)
                            }
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                if self.startResolved { return }
                self.startResolved = true
                throw MslError("VM start timed out")
            }

            try await group.next()
            group.cancelAll()
        }
    }

    func stop() async throws {
        guard let vm = vm else { throw MslError("VM not configured") }
        try await vm.stop()
    }

    func connectVsock(port: UInt32) async throws -> (handle: UnsafeMutableRawPointer, fd: Int32) {
        guard let vsock = vsock else { throw MslError("VSOCK not configured") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(UnsafeMutableRawPointer, Int32), Error>) in
            DispatchQueue.main.async {
                vsock.connect(toPort: port, completion: { handle, fd in
                    cont.resume(returning: (handle, fd))
                }, errorHandler: { error in
                    cont.resume(throwing: error)
                })
            }
        }
    }

    func connectVsock(port: UInt32, completion: @escaping (Result<(UnsafeMutableRawPointer, Int32), Error>) -> Void) {
        guard let vsock = vsock else {
            completion(.failure(MslError("VSOCK not configured")))
            return
        }
        vsock.connect(toPort: port, completion: { handle, fd in
            completion(.success((handle, fd)))
        }, errorHandler: { error in
            completion(.failure(error))
        })
    }

    func closeVsock(handle: UnsafeMutableRawPointer) {
        vsock?.closeSocket(handle)
    }

    func execOnGuest(_ command: String, timeout: Double = 120) async -> (Data, UInt32) {
        guard vsock != nil else { return (Data(), 255) }
        let handle: UnsafeMutableRawPointer
        let fd: Int32
        do {
            let conn = try await connectVsock(port: 9999)
            handle = conn.handle
            fd = conn.fd
        } catch {
            return (Data(), 255)
        }
        defer { self.closeVsock(handle: handle) }

        if !writeMslToken(fd) { return (Data(), 255) }

        var reqData = Data()
        reqData.append(0x00)
        var cmdLen = UInt32(command.utf8.count).bigEndian
        withUnsafeBytes(of: &cmdLen) { reqData.append(contentsOf: $0) }
        reqData.append(command.data(using: .utf8) ?? Data())
        var written = 0
        while written < reqData.count {
            let n = reqData.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress! + written, reqData.count - written)
            }
            if n <= 0 { return (Data(), 255) }
            written += n
        }

        let deadline = Date().addingTimeInterval(timeout)
        var outBuf = [UInt8](repeating: 0, count: 65536)
        var allOutput = Data()
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        while true {
            let remaining = max(0.0, deadline.timeIntervalSinceNow)
            if remaining <= 0 { break }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            var pret: Int32
            repeat { pret = poll(&pfd, 1, 1000) } while pret < 0 && errno == EINTR
            if pret < 0 { break }
            if pret == 0 { continue }

            let (n, savedErrno) = outBuf.withUnsafeMutableBytes { ptr -> (Int, Int32) in
                let bytesRead = read(fd, ptr.baseAddress!, ptr.count)
                return (bytesRead, errno)
            }
            if n > 0 { allOutput.append(outBuf, count: n) }
            else if n == 0 { break }
            else if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK { continue }
            else { break }
        }
        guard allOutput.count >= 4 else { return (allOutput, 255) }
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
        return (outputData, exitCode)
    }
}

// MARK: - Sendable conformance for ObjC bridge types

extension MSLVSOCK: @unchecked Sendable {}

extension MSLVM: VZVirtualMachineDelegate {
    private func markVMDead() {
        try? "dead".write(toFile: "\(dataDir)/vm.dead", atomically: true, encoding: .utf8)
        if let cb = onVMStopped { cb() }
    }

    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        mslLog("VM stopped with error: \(error.localizedDescription)")
        markVMDead()
    }

    func guestDidStop(_ vm: VZVirtualMachine) {
        mslLog("Guest OS stopped")
        markVMDead()
    }
}
