import Foundation
import ServiceManagement

/// Register/unregister the app as a login item via the modern `SMAppService`
/// (macOS 13+). Works best when the app lives in /Applications — registering
/// from a build folder can be rejected by the system.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Returns nil on success, or a short error string to show the user.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else {
            return "Launch at login needs macOS 13 or newer."
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Couldn't update login item — make sure the app is in /Applications."
        }
    }
}
