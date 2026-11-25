import Foundation
import LocalAuthentication

/// The real proof: macOS asks for Touch ID in its own dialog. The app never sees the fingerprint.
///
/// Touch ID only, by his call (2026-11-23): no login password and no Apple Watch, and the prompt
/// has no "Use Password" button. When Touch ID is out of reach (the lid closed on a desk, a lockout
/// after too many misses) the Vault stays locked until it can ask. When it is not set up (no
/// fingerprint, no login password, no sensor) the Vault is not used at all (2026-11-24).
public struct VaultDeviceOwnerProof: VaultAuthenticating {
    public init() {}

    /// The one policy the Vault asks under.
    static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics

    public var touchID: VaultTouchID {
        let context = LAContext()
        var cannot: NSError?
        if context.canEvaluatePolicy(Self.policy, error: &cannot) { return .ready }
        // `biometryType` is set by the question above, whatever it answered.
        return Self.touchID(cannot.flatMap { LAError.Code(rawValue: $0.code) }, sensor: context.biometryType != .none)
    }

    /// What macOS's answer means for the Vault. Out of reach only with a sensor this Mac knows
    /// (the lid closed, or a lockout); every other refusal is not set up, so the Vault is not used.
    static func touchID(_ code: LAError.Code?, sensor: Bool) -> VaultTouchID {
        switch code {
        case .passcodeNotSet?:
            return .notSetUp("This Mac has no login password, so Touch ID can’t be used. Set a login password and add a fingerprint in System Settings ▸ Touch ID & Password to use the Vault.")
        case .biometryNotEnrolled?:
            return .notSetUp("This Mac has no fingerprint for Touch ID. Add one in System Settings ▸ Touch ID & Password to use the Vault.")
        // A Touch ID keyboard paired with this Mac and unplugged, or out of range.
        case .biometryLockout?, .biometryDisconnected?:
            return .outOfReach
        case .biometryNotPaired?:
            return .notSetUp("This Mac has no Touch ID keyboard paired with it. Pair one, and add a fingerprint in System Settings ▸ Touch ID & Password, to use the Vault.")
        case .biometryNotAvailable? where sensor:
            return .outOfReach
        default:
            return sensor ? .outOfReach
                : .notSetUp("This Mac has no Touch ID. Use a Mac or keyboard with Touch ID, and add a fingerprint in System Settings ▸ Touch ID & Password, to use the Vault.")
        }
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

    /// Why macOS could not put up the prompt. "No password is set" means this Mac cannot ask at
    /// all; Touch ID out of reach, or no fingerprint, is a failure to ask again.
    static func cannotAsk(_ code: LAError.Code?, detail: String?) -> VaultProof {
        if code == .passcodeNotSet {
            return .unavailable("This Mac has no login password, so Touch ID can’t be used. Set a login password and add a fingerprint in System Settings ▸ Touch ID & Password to use the Vault.")
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
