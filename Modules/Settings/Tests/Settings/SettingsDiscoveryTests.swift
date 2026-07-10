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

/// A lister whose FIRST call blocks until the test releases it (returning `firstResult`);
/// later calls return `laterResults` immediately. Lets a test hold an older discovery pass
/// open off-main while a newer pass starts and finishes.
final class BlockingFirstCallLister: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let firstResult: [URL]
    private let laterResults: [URL]

    init(firstResult: [URL], laterResults: [URL]) {
        self.firstResult = firstResult
        self.laterResults = laterResults
    }

    var firstCallHasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls >= 1
    }

    func releaseFirstCall() {
        releaseFirst.signal()
    }

    func list() -> [URL] {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == 1 {
            releaseFirst.wait()
            return firstResult
        }
        return laterResults
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

// MARK: - CloudStorage enumeration

@Suite struct CloudStorageFoldersTests {

    /// A stray plain FILE named like a provider (e.g. "Dropbox") in ~/Library/CloudStorage
    /// must not surface as a selectable provider — its path can never be a valid root.
    @Test func testPlainFilesInTheScanDirectoryAreNotOffered() throws {
        let fm = FileManager.default
        let scanRoot = fm.temporaryDirectory.appendingPathComponent("SettingsListerTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scanRoot) }
        try fm.createDirectory(at: scanRoot.appendingPathComponent("OneDrive-Personal"), withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: scanRoot.appendingPathComponent("Dropbox").path, contents: Data()))

        let folders = SettingsManager.cloudStorageFolders(at: scanRoot)
        #expect(folders.map(\.lastPathComponent) == ["OneDrive-Personal"])
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

    @Test func testNameOverrideReplacesOnlyTheMatchingProviderName() {
        let names = [
            "GoogleDrive-someone@gmail.com": "Google Drive (Personal)",
            "Dropbox": "Dropbox (Work)",
        ]
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("GoogleDrive-someone@gmail.com"), folder("OneDrive-Work"), folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides,
            nameOverride: { names[$0] })

        #expect(providers.first(where: { $0.type == .googleDrive })?.displayName == "Google Drive (Personal)")
        #expect(providers.first(where: { $0.type == .dropBox })?.displayName == "Dropbox (Work)")
        // Providers without an override keep their discovered default.
        #expect(providers.first(where: { $0.type == .oneDrive })?.displayName == "OneDrive (Work)")
        #expect(providers.first(where: { $0.type == .iCloud })?.displayName == "iCloud")
    }

    @Test func testEmptyNameOverrideFallsBackToTheDefault() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("GoogleDrive-someone@gmail.com"), folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault, pathOverride: noOverrides,
            nameOverride: { _ in "" })

        #expect(providers.first(where: { $0.type == .googleDrive })?.displayName == "Google Drive (someone@gmail.com)")
        #expect(providers.first(where: { $0.type == .dropBox })?.displayName == "Dropbox")
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
    @Test func testSetCustomNameRoundTripAndClearRestoresDefaultName() async {
        let test = TestDefaults()
        defer { test.wipe() }

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { [folder("GoogleDrive-someone@gmail.com")] })
        await settings.discoverProviders()

        settings.setCustomName("Google Drive (Personal)", for: "GoogleDrive-someone@gmail.com")
        await settings.discoverProviders()
        #expect(test.defaults.string(forKey: "name_override_GoogleDrive-someone@gmail.com") == "Google Drive (Personal)")
        #expect(settings.availableProviders.first(where: { $0.type == .googleDrive })?.displayName == "Google Drive (Personal)")

        // Whitespace-only clears the override; the discovered default returns.
        settings.setCustomName("  ", for: "GoogleDrive-someone@gmail.com")
        await settings.discoverProviders()
        #expect(test.defaults.string(forKey: "name_override_GoogleDrive-someone@gmail.com") == nil)
        #expect(settings.availableProviders.first(where: { $0.type == .googleDrive })?.displayName == "Google Drive (someone@gmail.com)")
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

    /// Regression pin for the discovery race: each pass claims a generation at entry and may
    /// publish only if no newer pass has published — so an OLDER pass that finishes LAST (its
    /// off-main scan was slow) must not republish its stale provider snapshot over the newer one.
    @MainActor
    @Test func testStaleDiscoveryPassFinishingLastDoesNotOverwriteNewerResult() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let lister = BlockingFirstCallLister(
            firstResult: [folder("Dropbox")],
            laterResults: [folder("OneDrive-Personal")])

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { lister.list() })

        // Older pass: claims its generation, then blocks off-main inside the lister.
        let older = Task { await settings.discoverProviders() }
        var attempts = 0
        while !lister.firstCallHasStarted {
            attempts += 1
            if attempts > 5000 {
                Issue.record("older discovery pass never reached the lister")
                lister.releaseFirstCall()
                await older.value
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // Newer pass: starts after the older one but finishes first and publishes.
        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id) == ["iCloud", "OneDrive-Personal"])

        // Let the older pass finish last; its stale snapshot must be discarded.
        lister.releaseFirstCall()
        await older.value
        #expect(settings.availableProviders.map(\.id) == ["iCloud", "OneDrive-Personal"])
    }

    @MainActor
    @Test func testSetCustomNameStripsInteriorControlCharacters() async {
        let test = TestDefaults()
        defer { test.wipe() }

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { [folder("Dropbox")] })
        await settings.discoverProviders()

        // An embedded newline would forge an extra line in the single-line log records;
        // interior control characters each persist as a plain space instead.
        settings.setCustomName("Drop\nbox (Work)\u{07}", for: "Dropbox")
        let persisted = test.defaults.string(forKey: "name_override_Dropbox")
        #expect(persisted == "Drop box (Work)")
        #expect(persisted?.rangeOfCharacter(from: .controlCharacters) == nil)

        // A name that is only control characters clears the override like whitespace does.
        settings.setCustomName("\n\u{07}\n", for: "Dropbox")
        #expect(test.defaults.string(forKey: "name_override_Dropbox") == nil)
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
