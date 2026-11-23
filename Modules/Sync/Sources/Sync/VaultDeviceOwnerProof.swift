import Foundation
import LocalAuthentication

/// The real proof: macOS asks for Touch ID in its own dialog. The app never sees the fingerprint.
///
/// Touch ID only, by his call (2026-11-23): no login password and no Apple Watch, and the prompt
/// has no "Use Password" button. When Touch ID can't be used (the lid closed on a desk, a lockout
/// after too many misses, no fingerprint enrolled) the Vault stays locked until it can, and the
/// lock cannot be turned off either: each is a failure to ask again, never a way around the proof.
public struct VaultDeviceOwnerProof: VaultAuthenticating {
    public init() {}

    /// The one policy the Vault asks under.
    static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics

    /// Whether this Mac can ask right now. False with the lid closed, or no fingerprint enrolled.
    public static var canAsk: Bool {
        LAContext().canEvaluatePolicy(policy, error: nil)
    }

    /// A context per proof. One kept around would let a second request ride on the first's
    /// success for as long as the system allows reuse. An empty fallback title hides the prompt's
    /// password button.
    static func makeContext() -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        return context
    }

    public func prove(reason: String) async -> VaultProof {
        let context = Self.makeContext()
        var cannot: NSError?
        guard context.canEvaluatePolicy(Self.policy, error: &cannot) else {
            return Self.cannotAsk(cannot.flatMap { LAError.Code(rawValue: $0.code) },
                                  detail: cannot?.localizedDescription)
        }
        do {
            let allowed = try await context.evaluatePolicy(Self.policy, localizedReason: reason)
            return allowed ? .allowed : .failed("macOS couldn’t confirm it was you.")
        } catch let error as LAError {
            return Self.refused(error.code, detail: error.localizedDescription)
        } catch {
            return .failed("macOS couldn’t confirm it was you (\(error.localizedDescription)).")
        }
    }

    /// Why macOS could not put up the prompt. Only "no password is set" means this Mac cannot ask
    /// at all, which lets the lock be turned off without a proof. Touch ID being out of reach is a
    /// failure, so a closed lid or a lockout never opens the way to turning the lock off.
    static func cannotAsk(_ code: LAError.Code?, detail: String?) -> VaultProof {
        if code == .passcodeNotSet {
            return .unavailable("This Mac has no login password, so Touch ID can’t be set up. Set one in System Settings, or turn the Vault’s lock off in Settings.")
        }
        if let message = code.flatMap(touchIDMessage) { return .failed(message) }
        return .failed("macOS couldn’t ask for Touch ID right now (\(detail ?? "no reason given")). Try again in a moment.")
    }

    /// How a prompt that was put up ended without a match.
    static func refused(_ code: LAError.Code, detail: String) -> VaultProof {
        switch code {
        // The fallback button is hidden; were it ever shown and chosen, it is a dismissal, never
        // a password.
        case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
        default:
            if let message = touchIDMessage(code) { return .failed(message) }
            return .failed("macOS couldn’t confirm it was you (\(detail)).")
        }
    }

    /// What to do when Touch ID itself is out of reach.
    private static func touchIDMessage(_ code: LAError.Code) -> String? {
        switch code {
        case .biometryNotAvailable:
            return "Touch ID isn’t available right now. Open the Mac’s lid, or use a keyboard with Touch ID, and try again."
        case .biometryNotEnrolled:
            return "This Mac has no fingerprint for Touch ID. Add one in System Settings, then try again."
        case .biometryLockout:
            return "Touch ID is locked after too many tries. Lock the screen and unlock it with your password, then try again."
        default:
            return nil
        }
    }
}
