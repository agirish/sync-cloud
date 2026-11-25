import Foundation
import LocalAuthentication
import Testing
@testable import Sync

/// The Vault asks for Touch ID and only Touch ID: no password, no Watch, and Touch ID out of reach
/// is a failure. The lock is always on.
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

    /// A prompt macOS will not put up is a failure, never a proof.
    @Test(arguments: [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout])
    func aPromptMacOSWillNotPutUpIsAFailure(_ code: LAError.Code) async {
        let proof = VaultDeviceOwnerProof.cannotAsk(code, detail: nil)
        guard case .failed = proof else {
            Issue.record("\(code) answered \(proof), which is not a failure")
            return
        }
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
    }

    @Test func choosingTheFallbackIsADismissalNeverAPassword() {
        #expect(VaultDeviceOwnerProof.refused(.userFallback, detail: "x") == .cancelled)
        #expect(VaultDeviceOwnerProof.refused(.userCancel, detail: "x") == .cancelled)
        #expect(VaultDeviceOwnerProof.refused(.authenticationFailed, detail: "no match")
                == .failed("macOS couldn’t confirm it was you (no match)."))
    }
}

/// Without Touch ID set up the Vault is not used at all (owner, 2026-11-24): nothing is loaded,
/// read or asked for, and the panel says how to set it up. Out of reach (the lid closed, a
/// lockout) is not that: the Vault stays locked, as before.
@MainActor
@Suite struct VaultWithoutTouchIDTests {
    typealias Rig = VaultModelTests.Rig

    @Test func whatMacOSSaysIsReadAsSetUpOrNot() {
        let notSetUp: [(LAError.Code?, Bool)] = [(.passcodeNotSet, true), (.biometryNotEnrolled, true),
                                                (.biometryNotAvailable, false), (nil, false)]
        for (code, sensor) in notSetUp {
            guard case .notSetUp = VaultDeviceOwnerProof.touchID(code, sensor: sensor) else {
                Issue.record("\(String(describing: code)), sensor \(sensor): not read as not set up")
                continue
            }
        }
        #expect(VaultDeviceOwnerProof.touchID(.biometryNotAvailable, sensor: true) == .outOfReach, "the lid closed")
        #expect(VaultDeviceOwnerProof.touchID(.biometryLockout, sensor: true) == .outOfReach)
        #expect(VaultDeviceOwnerProof.touchID(.biometryDisconnected, sensor: false) == .outOfReach,
                "a paired Touch ID keyboard unplugged")
        #expect(VaultDeviceOwnerProof.touchID(nil, sensor: true) == .outOfReach)
        guard case .notSetUp = VaultDeviceOwnerProof.touchID(.biometryNotPaired, sensor: false) else {
            Issue.record("no Touch ID keyboard paired: not read as not set up")
            return
        }
    }

    /// Taken away while the Vault is unlocked (a fingerprint removed, the Vault kept open "even
    /// if closed"): coming back locks it and lets the numbers go.
    @Test func touchIDTakenAwayWhileUnlockedLetsTheNumbersGo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        rig.defaults.set(VaultLockSettings.Relock.afterTenMinutes.rawValue, forKey: VaultLockSettings.relockKey)
        let model = rig.model()
        await model.opened()
        #expect(model.isOpen && model.entries == [VaultModelTests.mortgage])
        model.closed()
        #expect(model.contents == .loaded, "kept open, even if closed")

        rig.auth.touchID = .notSetUp("Add a fingerprint.")
        await model.touchIDMayHaveChanged()
        #expect(model.contents == .notLoaded && model.entries.isEmpty)
        #expect(!model.isOpen)
        #expect(model.touchIDMissing == "Add a fingerprint.")

        // Set up again, and back to the front: it opens as it does at an open.
        rig.auth.touchID = .ready
        await model.touchIDMayHaveChanged()
        #expect(model.touchIDMissing == nil && model.entries == [VaultModelTests.mortgage])
    }

    @Test func withoutTouchIDNothingIsLoadedReadOrAskedFor() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        rig.auth.touchID = .notSetUp("Add a fingerprint.")
        let model = rig.model()

        await model.opened()
        #expect(model.touchIDMissing == "Add a fingerprint.")
        #expect(model.contents == .notLoaded && model.entries.isEmpty)
        #expect(await model.unlock() == false)
        let documents = VaultToConfirmTests.documents
        await model.readDocuments(with: documents)
        #expect(model.finds.isEmpty && model.contents == .notLoaded, "nothing was read into it")
        #expect(rig.auth.reasons.isEmpty, "Touch ID was never asked for")
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) == nil)
        #expect(try rig.store.load() == [VaultModelTests.mortgage], "nothing was written")

        // Set up while the app runs: the next open is the Vault's.
        rig.auth.touchID = .ready
        await model.opened()
        #expect(model.touchIDMissing == nil)
        #expect(rig.auth.reasons == ["unlock your Vault"])
        #expect(model.entries == [VaultModelTests.mortgage])
    }

    @Test func touchIDOutOfReachKeepsTheVaultLockedAsBefore() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        rig.auth.touchID = .outOfReach
        rig.auth.answer = .failed("Touch ID isn’t available right now.")
        let model = rig.model()
        await model.opened()
        #expect(model.touchIDMissing == nil, "not the setup message: Touch ID is there")
        #expect(model.isSealedShut && rig.auth.reasons == ["unlock your Vault"])
    }
}

