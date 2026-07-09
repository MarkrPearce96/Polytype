import Cocoa
import InputMethodKit

// The IMKServer must live for the whole process lifetime; a top-level `let`
// binding in main.swift keeps it retained. Its name must match the
// `InputMethodConnectionName` declared in the bundle's Info.plist so macOS can
// route keystrokes to us.
let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)

let app = NSApplication.shared
app.run()
