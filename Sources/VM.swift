import Foundation
@preconcurrency import Virtualization

// MARK: - Unchecked sendable wrappers for Virtualization framework types

private struct UncheckedVM: @unchecked Sendable {
    let value: VZVirtualMachine
    init(_ vm: VZVirtualMachine) { self.value = vm }
}

private struct UncheckedHandle: @unchecked Sendable {
    let value: UnsafeMutableRawPointer
    init(_ h: UnsafeMutableRawPointer) { self.value = h }
}

class MSLVM: NSObject {
    let dataDir: String
    let kernelPath: String
    let diskPath: String

    var vm: VZVirtualMachine?
    var vsock: MSLVSOCK?

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

        guard let disk = try? VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false) else {
            throw MslError("failed to open disk image at \(diskPath)")
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

        let serialPath = "/tmp/msl-serial.log"
        FileManager.default.createFile(atPath: serialPath, contents: nil)
        let serialFH = FileHandle(forWritingAtPath: serialPath) ?? FileHandle.standardError
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: serialFH
        )
        config.serialPorts = [serialPort]

        do {
            try config.validate()
        } catch {
            throw MslError("config invalid: \(error.localizedDescription)")
        }

        vm = VZVirtualMachine(configuration: config, queue: .main)
        vm?.delegate = self

        if let v = vm {
            vsock?.setVM(v)
        }
    }

    func start() async throws {
        guard let vm = vm else { throw MslError("VM not configured") }
        let uncheckedVM = UncheckedVM(vm)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.main.async {
                        uncheckedVM.value.start { result in
                            switch result {
                            case .success:
                                cont.resume()
                            case .failure(let err):
                                cont.resume(throwing: err)
                            }
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
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

    /// Run a command in the guest over VSOCK (mode 0x00) and return
    /// (combined stdout+stderr, exitCode). Synchronous, single connection.
    func execOnGuest(_ command: String, timeout: Double = 120) async -> (Data, UInt32) {
        guard let vsock = vsock else { return (Data(), 255) }
        let result: (UnsafeMutableRawPointer, Int32, Error?) = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                vsock.connect(toPort: 9999, completion: { handle, fd in
                    cont.resume(returning: (handle, fd, nil))
                }, errorHandler: { error in
                    // Use a sentinel: fd=-1 signals failure
                    cont.resume(returning: (UnsafeMutableRawPointer(bitPattern: 0)!, -1, error))
                })
            }
        }
        if result.1 < 0 { return (Data(), 255) }
        let handle = result.0
        let fd = result.1
        defer { self.closeVsock(handle: handle) }

        if !writeMslToken(fd) { return (Data(), 255) }

        var reqData = Data()
        reqData.append(0x00)
        var cmdLen = UInt32(command.utf8.count).bigEndian
        withUnsafeBytes(of: &cmdLen) { reqData.append(contentsOf: $0) }
        reqData.append(command.data(using: .utf8) ?? Data())
        var written = 0
        while written < reqData.count {
            let n = write(fd, (reqData as NSData).bytes + written, reqData.count - written)
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
            let (n, savedErrno) = outBuf.withUnsafeMutableBytes { ptr -> (Int, Int32) in
                let bytesRead = read(fd, ptr.baseAddress!, ptr.count)
                return (bytesRead, errno)
            }
            if n > 0 { allOutput.append(outBuf, count: n) }
            else if n == 0 { break }
            else if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK {
                usleep(10000)
                continue
            } else { break }
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
