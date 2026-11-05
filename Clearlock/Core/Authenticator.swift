import Foundation
import LocalAuthentication
import OpenDirectory

/// Verifies the current user with Touch ID or their macOS login password.
enum Authenticator {
    static var isTouchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var isTouchIDEnrolledOrPresent: Bool {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return true }
        return context.biometryType == .touchID
    }

    /// Checks the password against the local directory, off the main thread.
    static func verifyPassword(_ password: String) async -> Bool {
        let user = NSUserName()
        return await Task.detached(priority: .userInitiated) {
            do {
                let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
                let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
                try record.verifyPassword(password)
                return true
            } catch {
                return false
            }
        }.value
    }
}
