import AppKit
import Darwin

if let exitCode = HeadlessBootTest.runIfRequested() {
    exit(exitCode)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
_ = delegate
