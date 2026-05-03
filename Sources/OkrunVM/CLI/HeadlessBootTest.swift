import Foundation
import Virtualization

final class HeadlessBootTest: NSObject, VZVirtualMachineDelegate {
    private let kernelURL: URL
    private let initialRamdiskURL: URL
    private let timeout: TimeInterval
    private let sharedDirectory: SharedDirectoryConfig?
    private var expectedOutput: String {
        sharedDirectory == nil ? "OKRUN_E2E_BOOTED" : "OKRUN_E2E_SHARED_DIRS_PASSED"
    }
    private let completion = DispatchSemaphore(value: 0)
    private var virtualMachine: VZVirtualMachine?
    private var serialOutput = Data()
    private var result: Result<Void, Error>?

    init(kernelURL: URL, initialRamdiskURL: URL, timeout: TimeInterval, sharedDirectory: SharedDirectoryConfig?) {
        self.kernelURL = kernelURL
        self.initialRamdiskURL = initialRamdiskURL
        self.timeout = timeout
        self.sharedDirectory = sharedDirectory
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.contains("--headless-boot-test") else { return nil }

        do {
            let options = try parseOptions(arguments: arguments)
            let test = HeadlessBootTest(
                kernelURL: options.kernel,
                initialRamdiskURL: options.initialRamdisk,
                timeout: options.timeout,
                sharedDirectory: options.sharedDirectory
            )
            try test.run()
            print("Headless boot E2E passed: \(test.expectedOutput)")
            return 0
        } catch {
            fputs("Headless boot E2E failed: \(describeError(error))\n", stderr)
            return 1
        }
    }

    private static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        var message = error.localizedDescription
        message += " [domain: \(nsError.domain), code: \(nsError.code)]"
        if !nsError.userInfo.isEmpty {
            message += " userInfo: \(nsError.userInfo)"
        }
        return message
    }

    private static func parseOptions(arguments: [String]) throws -> (kernel: URL, initialRamdisk: URL, timeout: TimeInterval, sharedDirectory: SharedDirectoryConfig?) {
        var kernelPath: String?
        var initialRamdiskPath: String?
        var timeout: TimeInterval = 30
        var sharedDirectoryPath: String?
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--kernel":
                kernelPath = iterator.next()
            case "--initramfs":
                initialRamdiskPath = iterator.next()
            case "--timeout":
                guard let value = iterator.next(), let parsed = TimeInterval(value), parsed > 0 else {
                    throw AppError("--timeout must be a positive number of seconds.")
                }
                timeout = parsed
            case "--shared-directory":
                sharedDirectoryPath = iterator.next()
            default:
                continue
            }
        }

        guard let kernelPath else {
            throw AppError("Missing --kernel path.")
        }
        guard let initialRamdiskPath else {
            throw AppError("Missing --initramfs path.")
        }

        let kernel = URL(fileURLWithPath: kernelPath)
        let initialRamdisk = URL(fileURLWithPath: initialRamdiskPath)
        guard FileManager.default.fileExists(atPath: kernel.path) else {
            throw AppError("Kernel does not exist: \(kernel.path)")
        }
        guard FileManager.default.fileExists(atPath: initialRamdisk.path) else {
            throw AppError("Initramfs does not exist: \(initialRamdisk.path)")
        }

        let sharedDirectory = sharedDirectoryPath.map {
            SharedDirectoryConfig(name: "e2e", hostPath: $0, readOnly: false)
        }

        return (kernel, initialRamdisk, timeout, sharedDirectory)
    }

    private func run() throws {
        let outputPipe = Pipe()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendSerialOutput(data)
        }

        let configuration = try makeConfiguration(serialOutput: outputPipe.fileHandleForWriting)
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        virtualMachine = vm

        vm.start { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self?.finish(.failure(error))
                }
            }
        }

        let runLoopDeadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < runLoopDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        try stopVM()

        guard let result else {
            let output = String(decoding: serialOutput, as: UTF8.self)
            throw AppError("Timed out waiting for \(expectedOutput). Serial output:\n\(output)")
        }

        try result.get()
    }

    private func makeConfiguration(serialOutput: FileHandle) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()
        configuration.platform = platform

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initialRamdiskURL
        bootLoader.commandLine = "console=hvc0 panic=-1"
        configuration.bootLoader = bootLoader

        configuration.cpuCount = 1
        configuration.memorySize = 1024 * 1024 * 1024
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: serialOutput
        )
        configuration.serialPorts = [serialPort]
        configuration.directorySharingDevices = try DirectorySharingDeviceFactory.makeDevices(
            for: sharedDirectory.map { [$0] } ?? []
        )

        try configuration.validate()
        return configuration
    }

    private func appendSerialOutput(_ data: Data) {
        serialOutput.append(data)
        let output = String(decoding: serialOutput, as: UTF8.self)
        if output.contains(expectedOutput) {
            finish(.success(()))
        }
    }

    private func stopVM() throws {
        guard let virtualMachine else { return }
        if virtualMachine.canRequestStop {
            try? virtualMachine.requestStop()
            return
        }
        if virtualMachine.canStop {
            let stopSemaphore = DispatchSemaphore(value: 0)
            virtualMachine.stop { _ in
                stopSemaphore.signal()
            }
            _ = stopSemaphore.wait(timeout: .now() + 5)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        completion.signal()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finish(.failure(AppError("VM stopped before emitting \(expectedOutput).")))
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        finish(.failure(error))
    }
}
