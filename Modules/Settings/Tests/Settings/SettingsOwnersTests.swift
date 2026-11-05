import Testing
import Foundation
import Security
import ServiceManagement
import Design
import Events
@testable import Settings
import Sync

/// Pins the Settings work that lives in callable owners rather than views: the login-item round
/// trip, the log level's running logger, and the API key's confirmed removal, each testable
/// without mounting a view.
@MainActor
@Suite struct SettingsOwnersTests {

    // MARK: - Launch at login

    /// Stands in for `SMAppService.mainApp`: a status, and counts of the calls made against it.
    private final class FakeLoginService: @unchecked Sendable {
        private let lock = NSLock()
        private var _status: SMAppService.Status
        private var _registers = 0
        private var _unregisters = 0
        /// When set, `register` throws and leaves the status as it was.
        var registerFails = false

        init(status: SMAppService.Status) { _status = status }

        var registers: Int { lock.withLock { _registers } }
        var unregisters: Int { lock.withLock { _unregisters } }

        var service: LoginItemService {
            LoginItemService(
                status: { [self] in lock.withLock { _status } },
                register: { [self] in
                    try lock.withLock {
                        _registers += 1
                        if registerFails { throw CocoaError(.featureUnsupported) }
                        _status = .enabled
                    }
                },
                unregister: { [self] in
                    lock.withLock {
                        _unregisters += 1
                        _status = .notRegistered
                    }
                })
        }
    }

    @Test func aFlipRegistersOnceAndTheSwitchStaysOn() async {
        let fake = FakeLoginService(status: .notRegistered)
        let controller = LoginItemController(service: fake.service)

        controller.setFromUser(true)
        #expect(controller.isOn)
        let first = controller.lastRoundTrip
        await first?.value

        #expect(fake.registers == 1)
        #expect(controller.lastRoundTrip == first)   // no second round-trip followed
        #expect(controller.isOn)
        #expect(!controller.needsApproval)
    }

    @Test func aRefusedRegistrationPutsTheSwitchBack() async {
        let fake = FakeLoginService(status: .notRegistered)
        fake.registerFails = true
        let controller = LoginItemController(service: fake.service)

        controller.setFromUser(true)
        await controller.lastRoundTrip?.value

        #expect(fake.registers == 1)
        #expect(!controller.isOn)
        #expect(fake.unregisters == 0)
    }

    @Test func readingTheServiceStartsNoRoundTrip() async {
        // A status read is a programmatic set: it must reach the echo guard as an echo, never as a
        // gesture that registers (or unregisters) the item again.
        let fake = FakeLoginService(status: .enabled)
        let controller = LoginItemController(service: fake.service)

        await controller.refresh().value

        #expect(controller.isOn)
        #expect(controller.lastRoundTrip == nil)
    }

    @Test func aPendingApprovalReadsAsOnWithTheHint() async {
        // A pending item is the read that would register if it slipped past the echo guard as a
        // gesture (an enabled one wouldn't: `register` is skipped for it).
        let fake = FakeLoginService(status: .requiresApproval)
        let controller = LoginItemController(service: fake.service)

        await controller.refresh().value

        #expect(controller.isOn && controller.needsApproval)
        #expect(controller.lastRoundTrip == nil)
        #expect(fake.registers == 0)
    }

    // MARK: - Log level

    @Test func settingTheLogLevelStoresItAndTellsTheRunningLogger() {
        let suite = "SettingsOwnersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
        var told: [String] = []

        LogLevelSetting.set(.warning, in: defaults) { told.append($0) }

        #expect(defaults.string(forKey: Logger.minimumLevelDefaultsKey) == LogLevel.warning.rawValue)
        #expect(told == [LogLevel.warning.rawValue])
    }

    // MARK: - API key removal

    /// One Keychain item slot. `refuseDelete` keeps the item, as a locked keychain does.
    private final class FakeKeychain: KeychainStore, @unchecked Sendable {
        var hasItem = true
        var refuseDelete = false
        /// Refuses every write, as a locked keychain or an MDM policy does.
        var refuseWrite = false
        var writes = 0

        func delete(_ query: [String: Any]) -> OSStatus {
            if refuseDelete { return errSecInteractionNotAllowed }
            hasItem = false
            return errSecSuccess
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            if refuseWrite { return errSecInteractionNotAllowed }
            hasItem = true
            writes += 1
            return errSecSuccess
        }
        func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
            (hasItem ? errSecSuccess : errSecItemNotFound, nil)
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            if refuseWrite { return errSecInteractionNotAllowed }
            guard hasItem else { return errSecItemNotFound }
            writes += 1
            return errSecSuccess
        }
    }

    // MARK: - API key saving (TE290 step 7)

    @Test func aKeyFromACardIsSavedAsSettingsSavesIt() {
        let keychain = FakeKeychain()
        keychain.hasItem = false
        #expect(APIKeySaving.save("sk-ant-api03-abcdefghijklmnopqrstuvwxyz", in: keychain) == nil)
        #expect(keychain.hasItem && keychain.writes == 1)
        // Replaced in place.
        #expect(APIKeySaving.save("sk-ant-api03-zyxwvutsrqponmlkjihgfedcba", in: keychain) == nil)
        #expect(keychain.writes == 2)
    }

    @Test func aRefusedSaveSaysSoAndAnEmptyOneWritesNothing() {
        let keychain = FakeKeychain()
        keychain.refuseWrite = true
        let refusal = APIKeySaving.save("sk-ant-api03-abcdefghijklmnopqrstuvwxyz", in: keychain)
        #expect(refusal?.hasPrefix("Couldn’t save the key: macOS refused it") == true)
        #expect(refusal?.contains("The old key stays") == true)
        keychain.refuseWrite = false
        #expect(APIKeySaving.save("   ", in: keychain) == "Paste the key first.")
        #expect(keychain.writes == 0 && keychain.hasItem)
    }

    @Test func removingTheKeyReportsNothingWhenItIsGone() {
        let keychain = FakeKeychain()

        #expect(APIKeyRemoval.remove(from: keychain) == nil)
        #expect(!keychain.hasItem)
    }

    @Test func aRefusedRemovalSaysTheKeyIsStillStored() {
        let keychain = FakeKeychain()
        keychain.refuseDelete = true

        let refusal = APIKeyRemoval.remove(from: keychain)

        #expect(refusal?.contains("It is still stored") == true)
        #expect(refusal?.contains("\(errSecInteractionNotAllowed)") == true)
        #expect(keychain.hasItem)
    }

    // MARK: - Column widths

    @Test func theColumnRuleOutsideTheTabIsTheTabsRule() {
        var overrides = ColumnWidthOverrides()
        overrides.widths[2] = 180

        let declined = ColumnResizeChoice.choose(ColumnResizeMode.allColumns.rawValue,
                                                 overrides: overrides, confirm: { false })
        #expect(declined == nil, "a declined All columns still produced something to store")

        let confirmed = ColumnResizeChoice.choose(ColumnResizeMode.allColumns.rawValue,
                                                  overrides: overrides, confirm: { true })
        #expect(confirmed?.mode == ColumnResizeMode.allColumns.rawValue)
        #expect(confirmed?.overrides.widths.isEmpty == true)
    }
}
