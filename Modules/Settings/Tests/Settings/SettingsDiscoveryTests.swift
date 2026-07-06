import Testing
import Foundation
@testable import Settings
import Sync

// MARK: - Shared test helpers

/// A fresh UserDefaults suite isolated from .standard; callers must call `wipe()` when done.
struct TestDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init(_ function: String = #function) {
        self.suiteName = "SettingsTests-\(function)-\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: suiteName)!
    }

    func wipe() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Thread-safe call counter usable from the @Sendable CloudStorageLister.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage")
private func folder(_ name: String) -> URL { root.appendingPathComponent(name) }
private let iCloudDefault = "/Users/test/Documents"
private func noOverrides(_ id: String) -> String? { nil }

// MARK: - mapProviders: parsing

@Suite struct MapProvidersParsingTests {

    @Test func testICloudIsAlwaysPresentEvenWithNoFolders() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [], iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides)

        #expect(providers.count == 1)
        #expect(providers[0].id == "iCloud")
        #expect(providers[0].displayName == "iCloud")
        #expect(providers[0].imageName == "icloud")
        #expect(providers[0].path == iCloudDefault)
        #expect(providers[0].type == .iCloud)
    }

    @Test func testOneDrivePrefixParsesAccountSuffixAndDocumentsPath() throws {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("OneDrive-Personal")],
            iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides)

        let oneDrive = try #require(providers.first(where: { $0.type == .oneDrive }))
        #expect(oneDrive.id == "OneDrive-Personal")
        #expect(oneDrive.displayName == "OneDrive (Personal)")
        #expect(oneDrive.imageName == "onedrive")
        #expect(oneDrive.path == "/Users/test/Library/CloudStorage/OneDrive-Personal/Documents")
    }

    @Test func testGoogleDrivePrefixParsesAccountAndMyDriveDocumentsPath() throws {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("GoogleDrive-someone@gmail.com")],
            iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides)

        let drive = try #require(providers.first(where: { $0.type == .googleDrive }))
        #expect(drive.id == "GoogleDrive-someone@gmail.com")
        #expect(drive.displayName == "Google Drive (someone@gmail.com)")
        #expect(drive.imageName == "googledrive")
        #expect(drive.path == "/Users/test/Library/CloudStorage/GoogleDrive-someone@gmail.com/My Drive/Documents")
    }

    @Test func testDropboxRequiresExactNameAndUsesDocumentsPath() throws {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides)

        let dropbox = try #require(providers.first(where: { $0.type == .dropBox }))
        #expect(dropbox.id == "Dropbox")
        #expect(dropbox.displayName == "Dropbox")
        #expect(dropbox.imageName == "dropbox")
        #expect(dropbox.path == "/Users/test/Library/CloudStorage/Dropbox/Documents")
    }

    @Test func testUnrecognizedFoldersAreIgnored() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [
                folder("Box-Work"),           // unsupported provider
                folder("OneDrive"),           // missing the -account suffix separator
                folder("GoogleDrive"),        // missing the -account suffix separator
                folder("Dropbox-Business"),   // Dropbox must match exactly
                folder("onedrive-personal"),  // prefixes are case-sensitive
            ],
            iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides)

        #expect(providers.map(\.id) == ["iCloud"])
    }
}

// MARK: - mapProviders: sorting

@Suite struct MapProvidersSortingTests {

    @Test func testProvidersSortByTypeGroupThenDisplayName() {
        // Deliberately shuffled input order.
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [
                folder("Dropbox"),
                folder("GoogleDrive-zoe@gmail.com"),
                folder("OneDrive-Work"),
                folder("GoogleDrive-adam@gmail.com"),
                folder("OneDrive-Personal"),
            ],
            iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides)

        #expect(providers.map(\.id) == [
            "iCloud",
            "OneDrive-Personal",
            "OneDrive-Work",
            "GoogleDrive-adam@gmail.com",
            "GoogleDrive-zoe@gmail.com",
            "Dropbox",
        ])
    }
}

// MARK: - mapProviders: overrides

@Suite struct MapProvidersOverrideTests {

    @Test func testOverrideReplacesOnlyTheMatchingProviderPath() {
        let overrides = ["OneDrive-Personal": "/Volumes/External/OneDrive"]
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("OneDrive-Personal"), folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault, pathOverride: { overrides[$0] })

        #expect(providers.first(where: { $0.id == "OneDrive-Personal" })?.path == "/Volumes/External/OneDrive")
        #expect(providers.first(where: { $0.id == "Dropbox" })?.path == "/Users/test/Library/CloudStorage/Dropbox/Documents")
        #expect(providers.first(where: { $0.id == "iCloud" })?.path == iCloudDefault)
    }

    @Test func testICloudOverrideBeatsTheDefaultPath() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [], iCloudDefaultPath: iCloudDefault,
            pathOverride: { $0 == "iCloud" ? "/Users/test/CustomDocs" : nil })

        #expect(providers.first(where: { $0.id == "iCloud" })?.path == "/Users/test/CustomDocs")
    }
}

// MARK: - SettingsManager with injected seams

@Suite struct SettingsManagerInjectionTests {

    @MainActor
    @Test func testDiscoverProvidersUsesInjectedListerAndDefaults() async {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set("/Volumes/External/OneDrive", forKey: "path_override_OneDrive-Personal")

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { [folder("OneDrive-Personal"), folder("Dropbox")] })
        await settings.discoverProviders()

        #expect(settings.availableProviders.map(\.id) == ["iCloud", "OneDrive-Personal", "Dropbox"])
        #expect(settings.path(for: "OneDrive-Personal") == "/Volumes/External/OneDrive")
        #expect(settings.path(for: "Dropbox") == "/Users/test/Library/CloudStorage/Dropbox/Documents")
    }

    @MainActor
    @Test func testSetPathResetPathRoundTripWithoutGlobalState() async {
        let test = TestDefaults()
        defer { test.wipe() }

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { [folder("Dropbox")] })
        await settings.discoverProviders()

        let defaultPath = settings.path(for: "Dropbox")
        settings.setPath("/tmp/dropbox-elsewhere", for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.path(for: "Dropbox") == "/tmp/dropbox-elsewhere")
        #expect(test.defaults.string(forKey: "path_override_Dropbox") == "/tmp/dropbox-elsewhere")

        settings.resetPath(for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.path(for: "Dropbox") == defaultPath)
        #expect(test.defaults.string(forKey: "path_override_Dropbox") == nil)
    }

    @MainActor
    @Test func testIgnoreGoogleDriveFlagRoundTripsThroughInjectedDefaults() {
        let test = TestDefaults()
        defer { test.wipe() }

        let a = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { [] })
        a.ignoreGoogleDriveNewerDateOnly = true // didSet persists
        // A fresh instance on the same suite reads the persisted value in init.
        #expect(SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { [] }).ignoreGoogleDriveNewerDateOnly == true)

        a.ignoreGoogleDriveNewerDateOnly = false
        #expect(SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { [] }).ignoreGoogleDriveNewerDateOnly == false)
    }

    @MainActor
    @Test func testAutoDiscoverFalseNeverListsAndExplicitDiscoveryListsOnce() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let counter = CallCounter()

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { counter.increment(); return [] })
        #expect(counter.count == 0)

        await settings.discoverProviders()
        #expect(counter.count == 1)
    }

    /// Every discovery pass must re-run the path validator, even when it changes no provider:
    /// the validity badge shows `pathValidity`, and "Refresh providers" often leaves a card's
    /// identity and path unchanged while the folder on disk appeared or vanished. (Successor to
    /// the `providerDiscoveryCount` bump test — the counter was subsumed by `pathValidity`.)
    @MainActor
    @Test func testDiscoverProvidersRevalidatesPathsEvenWhenProvidersAreUnchanged() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let counter = CallCounter()

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { [folder("Dropbox")] },
            pathValidator: { _ in counter.increment(); return true })

        await settings.discoverProviders()
        let providersAfterFirst = settings.availableProviders.map(\.id)
        let validationsAfterFirst = counter.count
        #expect(validationsAfterFirst >= providersAfterFirst.count)

        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id) == providersAfterFirst)
        #expect(counter.count == validationsAfterFirst + providersAfterFirst.count)
    }
}
