import AppKit
import Darwin

enum InstanceLauncher {
    private static let childEnvironmentKey = "OKRUN_VM_CHILD_INSTANCE"

    static func continueOrSpawnChild() {
        guard ProcessInfo.processInfo.environment[childEnvironmentKey] != "1" else {
            return
        }

        do {
            try spawnChild()
            exit(0)
        } catch {
            return
        }
    }

    static func spawnChild() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw AppError("Unable to locate app executable.")
        }

        var environment = ProcessInfo.processInfo.environment
        environment[childEnvironmentKey] = "1"

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Array(CommandLine.arguments.dropFirst())
        process.environment = environment
        try process.run()
    }
}

if let exitCode = HeadlessBootTest.runIfRequested() {
    exit(exitCode)
}

InstanceLauncher.continueOrSpawnChild()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
_ = delegate
