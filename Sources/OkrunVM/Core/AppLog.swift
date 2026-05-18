import Foundation
import OSLog

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.okrun.vm"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let virtualMachine = Logger(subsystem: subsystem, category: "virtual-machine")
    static let webSwitch = Logger(subsystem: subsystem, category: "web-switch")
}
