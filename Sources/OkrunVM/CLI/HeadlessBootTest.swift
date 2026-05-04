import Darwin
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
        guard arguments.contains("--headless-boot-test")
            || arguments.contains("--headless-save-restore-test")
            || arguments.contains("--headless-project-save-restore-test") else {
            return nil
        }

        do {
            let options = try parseOptions(arguments: arguments)
            if arguments.contains("--headless-project-save-restore-test") {
                guard let projectRoot = options.projectRoot else {
                    throw AppError("Missing --project-root path.")
                }
                let test = HeadlessProjectSaveRestoreTest(projectRoot: projectRoot, timeout: options.timeout)
                try test.run()
                print("Headless project save/restore E2E passed: \(projectRoot.path)")
                return 0
            }

            if arguments.contains("--headless-save-restore-test") {
                let test = HeadlessSaveRestoreTest(
                    kernelURL: options.kernel,
                    initialRamdiskURL: options.initialRamdisk,
                    timeout: options.timeout,
                    sharedDirectory: options.sharedDirectory
                )
                try test.run()
                print("Headless save/restore E2E passed: OKRUN_E2E_SAVE_RESTORE_RESUMED")
                return 0
            }

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

    fileprivate static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        var message = error.localizedDescription
        message += " [domain: \(nsError.domain), code: \(nsError.code)]"
        if !nsError.userInfo.isEmpty {
            message += " userInfo: \(nsError.userInfo)"
        }
        return message
    }

    private static func parseOptions(
        arguments: [String]
    ) throws -> (
        kernel: URL,
        initialRamdisk: URL,
        timeout: TimeInterval,
        sharedDirectory: SharedDirectoryConfig?,
        projectRoot: URL?
    ) {
        var kernelPath: String?
        var initialRamdiskPath: String?
        var timeout: TimeInterval = 30
        var sharedDirectoryPath: String?
        var projectRootPath: String?
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
            case "--project-root":
                projectRootPath = iterator.next()
            default:
                continue
            }
        }

        let projectRoot = projectRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if projectRoot == nil {
            guard kernelPath != nil else {
                throw AppError("Missing --kernel path.")
            }
            guard initialRamdiskPath != nil else {
                throw AppError("Missing --initramfs path.")
            }
        }

        let kernel = URL(fileURLWithPath: kernelPath ?? "/")
        let initialRamdisk = URL(fileURLWithPath: initialRamdiskPath ?? "/")
        if projectRoot == nil && !FileManager.default.fileExists(atPath: kernel.path) {
            throw AppError("Kernel does not exist: \(kernel.path)")
        }
        if projectRoot == nil && !FileManager.default.fileExists(atPath: initialRamdisk.path) {
            throw AppError("Initramfs does not exist: \(initialRamdisk.path)")
        }

        let sharedDirectory = sharedDirectoryPath.map {
            SharedDirectoryConfig(name: "e2e", hostPath: $0, readOnly: false)
        }

        return (kernel, initialRamdisk, timeout, sharedDirectory, projectRoot)
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

final class HeadlessSaveRestoreTest: NSObject, VZVirtualMachineDelegate {
    private let kernelURL: URL
    private let initialRamdiskURL: URL
    private let timeout: TimeInterval
    private let sharedDirectory: SharedDirectoryConfig?
    private let machineIdentifier = VZGenericMachineIdentifier()
    private let stateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("okrun-save-restore-\(UUID().uuidString).state")
    private var virtualMachine: VZVirtualMachine?
    private var serialOutput = Data()
    private var stopError: Error?

    init(
        kernelURL: URL,
        initialRamdiskURL: URL,
        timeout: TimeInterval,
        sharedDirectory: SharedDirectoryConfig?
    ) {
        self.kernelURL = kernelURL
        self.initialRamdiskURL = initialRamdiskURL
        self.timeout = timeout
        self.sharedDirectory = sharedDirectory
    }

    func run() throws {
        guard #available(macOS 14.0, *) else {
            throw AppError("Save/restore E2E requires macOS 14 or newer.")
        }

        defer { try? FileManager.default.removeItem(at: stateURL) }

        let outputPipe = Pipe()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.serialOutput.append(data)
        }
        defer { outputPipe.fileHandleForReading.readabilityHandler = nil }

        let firstConfiguration = try makeConfiguration(serialOutput: outputPipe.fileHandleForWriting)
        let firstVM = VZVirtualMachine(configuration: firstConfiguration)
        firstVM.delegate = self
        virtualMachine = firstVM

        try start(firstVM)
        try waitForSerialMarker("OKRUN_E2E_SAVE_RESTORE_BOOTED")
        try pause(firstVM)
        try validateSaveRestoreSupport(firstConfiguration, phase: "initial synthetic")
        try save(firstVM, to: stateURL)
        try stop(firstVM)
        virtualMachine = nil

        let restoredConfiguration = try makeConfiguration(serialOutput: outputPipe.fileHandleForWriting)
        try validateSaveRestoreSupport(restoredConfiguration, phase: "restored synthetic")
        let restoredVM = VZVirtualMachine(configuration: restoredConfiguration)
        restoredVM.delegate = self
        virtualMachine = restoredVM

        try restore(restoredVM, from: stateURL)
        try resume(restoredVM)
        try waitForSerialMarker("OKRUN_E2E_SAVE_RESTORE_RESUMED")
        try stop(restoredVM)
        virtualMachine = nil
    }

    private func makeConfiguration(serialOutput: FileHandle) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier
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

    @available(macOS 14.0, *)
    private func validateSaveRestoreSupport(_ configuration: VZVirtualMachineConfiguration, phase: String) throws {
        do {
            try configuration.validateSaveRestoreSupport()
        } catch {
            throw AppError("\(phase) save/restore validation failed: \(HeadlessBootTest.describeError(error))")
        }
    }

    private func start(_ vm: VZVirtualMachine) throws {
        var completed = false
        var startError: Error?
        vm.start { result in
            if case .failure(let error) = result {
                startError = error
            }
            completed = true
        }
        try waitForCompletion("start", completed: { completed })
        if let startError {
            throw AppError("Synthetic save/restore start failed: \(HeadlessBootTest.describeError(startError))")
        }
    }

    @available(macOS 14.0, *)
    private func restore(_ vm: VZVirtualMachine, from url: URL) throws {
        var completed = false
        var restoreError: Error?
        vm.restoreMachineStateFrom(url: url) { error in
            restoreError = error
            completed = true
        }
        try waitForCompletion("restore", completed: { completed })
        if let restoreError {
            throw restoreError
        }
    }

    private func pause(_ vm: VZVirtualMachine) throws {
        var completed = false
        var pauseError: Error?
        vm.pause { result in
            if case .failure(let error) = result {
                pauseError = error
            }
            completed = true
        }
        try waitForCompletion("pause", completed: { completed })
        if let pauseError {
            throw pauseError
        }
    }

    @available(macOS 14.0, *)
    private func save(_ vm: VZVirtualMachine, to url: URL) throws {
        var completed = false
        var saveError: Error?
        vm.saveMachineStateTo(url: url) { error in
            saveError = error
            completed = true
        }
        try waitForCompletion("save", completed: { completed })
        if let saveError {
            throw saveError
        }
    }

    private func resume(_ vm: VZVirtualMachine) throws {
        var completed = false
        var resumeError: Error?
        vm.resume { result in
            if case .failure(let error) = result {
                resumeError = error
            }
            completed = true
        }
        try waitForCompletion("resume", completed: { completed })
        if let resumeError {
            throw resumeError
        }
    }

    private func stop(_ vm: VZVirtualMachine) throws {
        guard vm.canStop else { return }

        var completed = false
        var stopError: Error?
        vm.stop { error in
            stopError = error
            completed = true
        }
        try waitForCompletion("stop", timeout: 5, completed: { completed })
        if let stopError {
            throw stopError
        }
    }

    private func waitForCompletion(
        _ operation: String,
        timeout operationTimeout: TimeInterval? = nil,
        completed: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(operationTimeout ?? timeout)
        while !completed() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard completed() else {
            throw AppError("Timed out waiting for save/restore \(operation).")
        }
    }

    private func waitForSerialMarker(_ marker: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let stopError {
                throw stopError
            }

            let output = String(decoding: serialOutput, as: UTF8.self)
            if output.contains(marker) {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let output = String(decoding: serialOutput, as: UTF8.self)
        throw AppError("Timed out waiting for \(marker). Serial output:\n\(output)")
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stopError = AppError("VM stopped before save/restore E2E completed.")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stopError = error
    }
}

final class HeadlessProjectSaveRestoreTest: NSObject, VZVirtualMachineDelegate {
    private let projectRoot: URL
    private let timeout: TimeInterval
    private let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("okrun-project-save-restore-\(UUID().uuidString)", isDirectory: true)
    private var paths: VMPaths!
    private var config: VMConfig!
    private var diskOverride: URL?
    private var virtualMachine: VZVirtualMachine?
    private var stopError: Error?

    init(projectRoot: URL, timeout: TimeInterval) {
        self.projectRoot = projectRoot
        self.timeout = timeout
    }

    func run() throws {
        guard #available(macOS 14.0, *) else {
            throw AppError("Project save/restore E2E requires macOS 14 or newer.")
        }

        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try cloneProject()

        let firstConfiguration = try makeConfiguration()
        try validateSaveRestoreSupport(firstConfiguration, phase: "initial project")
        let firstVM = VZVirtualMachine(configuration: firstConfiguration)
        firstVM.delegate = self
        virtualMachine = firstVM

        try start(firstVM)
        try waitForGuestSettle()
        try pause(firstVM)
        try copyFile(from: paths.efiStore, to: paths.savedStateEfiStore)
        try copyFile(from: paths.disk, to: paths.savedStateDisk)
        try save(firstVM, to: paths.machineState)
        try stop(firstVM)
        virtualMachine = nil

        try copyFile(from: paths.savedStateEfiStore, to: paths.efiStore)
        diskOverride = paths.savedStateDisk
        let restoredConfiguration = try makeConfiguration()
        try validateSaveRestoreSupport(restoredConfiguration, phase: "restored project")
        let restoredVM = VZVirtualMachine(configuration: restoredConfiguration)
        restoredVM.delegate = self
        virtualMachine = restoredVM

        try restore(restoredVM, from: paths.machineState)
        try resume(restoredVM)
        try waitForGuestSettle()
        try stop(restoredVM)
        virtualMachine = nil
    }

    private func cloneProject() throws {
        let sourcePaths = VMPaths.project(at: projectRoot)
        let targetPaths = VMPaths.project(at: temporaryRoot)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: targetPaths.vmDirectory, withIntermediateDirectories: true)
        try copyFile(from: sourcePaths.config, to: targetPaths.config)
        try copyFile(from: sourcePaths.disk, to: targetPaths.disk)
        try copyFile(from: sourcePaths.efiStore, to: targetPaths.efiStore)
        try copyFile(from: sourcePaths.machineIdentifier, to: targetPaths.machineIdentifier)

        paths = targetPaths
        config = try VMConfig.load(from: targetPaths.config)
    }

    private func copyFile(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AppError("Missing project save/restore fixture file: \(source.path)")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if clonefile(source.path, destination.path, 0) != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        let machineData = try Data(contentsOf: paths.machineIdentifier)
        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineData) else {
            throw AppError("Invalid machine identifier at \(paths.machineIdentifier.path)")
        }
        platform.machineIdentifier = machineIdentifier
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: paths.efiStore)
        configuration.bootLoader = bootLoader

        configuration.cpuCount = min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(
            UInt64(config.memoryGB) * 1024 * 1024 * 1024,
            VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
        configuration.graphicsDevices = [makeGraphicsDevice()]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.networkDevices = [makeNetworkDevice()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.storageDevices = [try makeStorageDevice()]
        configuration.directorySharingDevices = try DirectorySharingDeviceFactory.makeDevices(for: config.sharedDirectories)

        do {
            try configuration.validate()
        } catch {
            throw AppError("Project save/restore configuration validation failed: \(HeadlessBootTest.describeError(error))")
        }
        return configuration
    }

    @available(macOS 14.0, *)
    private func validateSaveRestoreSupport(_ configuration: VZVirtualMachineConfiguration, phase: String) throws {
        do {
            try configuration.validateSaveRestoreSupport()
        } catch {
            throw AppError("\(phase) save/restore validation failed: \(HeadlessBootTest.describeError(error))")
        }
    }

    private func makeGraphicsDevice() -> VZGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)
        ]
        return graphicsDevice
    }

    private func makeNetworkDevice() -> VZNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
    }

    private func makeStorageDevice() throws -> VZStorageDeviceConfiguration {
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskOverride ?? paths.disk, readOnly: false)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    private func start(_ vm: VZVirtualMachine) throws {
        var completed = false
        var startError: Error?
        vm.start { result in
            if case .failure(let error) = result {
                startError = error
            }
            completed = true
        }
        try waitForCompletion("start", completed: { completed })
        if let startError {
            throw AppError("Project save/restore start failed: \(HeadlessBootTest.describeError(startError))")
        }
    }

    private func pause(_ vm: VZVirtualMachine) throws {
        var completed = false
        var pauseError: Error?
        vm.pause { result in
            if case .failure(let error) = result {
                pauseError = error
            }
            completed = true
        }
        try waitForCompletion("pause", completed: { completed })
        if let pauseError {
            throw pauseError
        }
    }

    @available(macOS 14.0, *)
    private func save(_ vm: VZVirtualMachine, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        var completed = false
        var saveError: Error?
        vm.saveMachineStateTo(url: url) { error in
            saveError = error
            completed = true
        }
        try waitForCompletion("save", completed: { completed })
        if let saveError {
            throw saveError
        }
    }

    @available(macOS 14.0, *)
    private func restore(_ vm: VZVirtualMachine, from url: URL) throws {
        var completed = false
        var restoreError: Error?
        vm.restoreMachineStateFrom(url: url) { error in
            restoreError = error
            completed = true
        }
        try waitForCompletion("restore", completed: { completed })
        if let restoreError {
            throw restoreError
        }
    }

    private func resume(_ vm: VZVirtualMachine) throws {
        var completed = false
        var resumeError: Error?
        vm.resume { result in
            if case .failure(let error) = result {
                resumeError = error
            }
            completed = true
        }
        try waitForCompletion("resume", completed: { completed })
        if let resumeError {
            throw resumeError
        }
    }

    private func stop(_ vm: VZVirtualMachine) throws {
        guard vm.canStop else { return }

        var completed = false
        var stopError: Error?
        vm.stop { error in
            stopError = error
            completed = true
        }
        try waitForCompletion("stop", timeout: 5, completed: { completed })
        if let stopError {
            throw stopError
        }
    }

    private func waitForGuestSettle() throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let stopError {
                throw stopError
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func waitForCompletion(
        _ operation: String,
        timeout operationTimeout: TimeInterval? = nil,
        completed: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(operationTimeout ?? timeout)
        while !completed() && Date() < deadline {
            if let stopError {
                throw stopError
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard completed() else {
            throw AppError("Timed out waiting for project save/restore \(operation).")
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stopError = AppError("VM stopped before project save/restore E2E completed.")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stopError = error
    }
}
