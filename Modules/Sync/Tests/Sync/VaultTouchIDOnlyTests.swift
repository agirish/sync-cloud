import Foundation
import LocalAuthentication
import Testing
@testable import Sync

/// The Vault asks for Touch ID and only Touch ID: no password, no Watch, and Touch ID out of reach
/// is a failure, never a way to turn the lock off.
@Suite struct VaultTouchIDOnlyTests {
    @Test func theVaultAsksUnderTheBiometricsOnlyPolicy() {
        // `.deviceOwnerAuthentication` would let the login password through.
        #expect(VaultDeviceOwnerProof.policy == .deviceOwnerAuthenticationWithBiometrics)
    }

    @Test func thePromptHasNoPasswordButtonAndNoReuse() {
        let context = VaultDeviceOwnerProof.makeContext()
        #expect(context.localizedFallbackTitle == "", "a nil title shows macOS's Use Password button")
        #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
    }

    @Test(arguments: [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout])
    func touchIDOutOfReachKeepsTheLockOn(_ code: LAError.Code) async {
        let proof = VaultDeviceOwnerProof.cannotAsk(code, detail: nil)
        guard case .failed = proof else {
            Issue.record("\(code) answered \(proof), which is not a failure")
            return
        }
        let auth = VaultFakeAuthenticator()
        auth.answer = proof
        #expect(await !VaultLockSwitch.mayTurnOff(using: auth),
                "with Touch ID out of reach (\(code)) the lock came off without a proof")
    }

    @Test func eachWayTouchIDIsOutOfReachSaysWhatToDo() {
        #expect(VaultDeviceOwnerProof.cannotAsk(.biometryNotAvailable, detail: nil)
                == .failed("Touch ID isn’t available right now. Open the Mac’s lid, or use a keyboard with Touch ID, and try again."))
        #expect(VaultDeviceOwnerProof.cannotAsk(.biometryNotEnrolled, detail: nil)
                == .failed("This Mac has no fingerprint for Touch ID. Add one in System Settings, then try again."))
        #expect(VaultDeviceOwnerProof.refused(.biometryLockout, detail: "x")
                == .failed("Touch ID is locked after too many tries. Lock the screen and unlock it with your password, then try again."))
    }

    @Test func onlyAMacWithNoLoginPasswordCannotAsk() async {
        let proof = VaultDeviceOwnerProof.cannotAsk(.passcodeNotSet, detail: nil)
        guard case .unavailable = proof else {
            Issue.record("no login password answered \(proof)")
            return
        }
        let auth = VaultFakeAuthenticator()
        auth.answer = proof
        #expect(await VaultLockSwitch.mayTurnOff(using: auth))
    }

    @Test func choosingTheFallbackIsADismissalNeverAPassword() {
        #expect(VaultDeviceOwnerProof.refused(.userFallback, detail: "x") == .cancelled)
        #expect(VaultDeviceOwnerProof.refused(.userCancel, detail: "x") == .cancelled)
        #expect(VaultDeviceOwnerProof.refused(.authenticationFailed, detail: "no match")
                == .failed("macOS couldn’t confirm it was you (no match)."))
    }
}
