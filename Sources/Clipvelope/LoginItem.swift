import Foundation
import ServiceManagement

// MARK: - Login Item

enum LoginItemController {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            NSLog("Login item error: \(error)")
            return error
        }
    }
}
