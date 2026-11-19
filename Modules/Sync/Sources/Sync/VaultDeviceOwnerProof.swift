import Foundation
import LocalAuthentication

/// The real proof: macOS asks for Touch ID, an Apple Watch or the login password, whichever this
/// Mac has, in its own dialog. The app never sees what was typed.
///
/// `deviceOwnerAuthentication`, not the biometrics-only policy: a Mac with no Touch ID, a lid
/// closed on a desk, and a finger that won't read all fall back to the password instead of
/// locking the owner out of their own numbers.
public struct VaultDeviceOwnerProof: VaultAuthenticating {
    public init() {}

    /// Whether this Mac can ask at all. False with no login password set.
    public static var canAsk: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public func prove(reason: String) async -> VaultProof {
        // A context per proof. One kept around would let a second request ride on the first's
        // success for as long as the system allows reuse.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var cannot: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &cannot) else {
            return .unavailable("This Mac has no login password or Touch ID to ask for. Set one in System Settings, or turn the Vault’s lock off in Settings.")
        }
        do {
            let allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return allowed ? .allowed : .failed("macOS couldn’t confirm it was you.")
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            default: return .failed("macOS couldn’t confirm it was you (\(error.localizedDescription)).")
            }
        } catch {
            return .failed("macOS couldn’t confirm it was you (\(error.localizedDescription)).")
        }
    }
}
