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
        wipeDefaultsSuite(suiteName)
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
            cloudStorageFolders: [], iCloudDefaultPath: iCloudDefault)

        #expect(providers.count == 1)
        #expect(providers[0].id == "iCloud")
        #expect(providers[0].displayName == "iCloud")
        #expect(providers[0].imageName == "icloud")
        #expect(providers[0].rootPath == iCloudDefault)
        // Lands at its own root: iCloud's real Drive root holds only hidden symlinks to the folders
        // that matter, so `~/Documents` is both the top of this source and where panes open.
        // See `CloudProvider.rootPath`.
        #expect(providers[0].openAt == "")
        #expect(providers[0].landingPath == iCloudDefault)
        #expect(providers[0].type == .iCloud)
    }

    @Test func testOneDrivePrefixParsesAccountSuffixAndDocumentsPath() throws {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("OneDrive-Personal")],
            iCloudDefaultPath: iCloudDefault)

        let oneDrive = try #require(providers.first(where: { $0.type == .oneDrive }))
        #expect(oneDrive.id == "OneDrive-Personal")
        #expect(oneDrive.displayName == "OneDrive (Personal)")
        #expect(oneDrive.imageName == "onedrive")
        // The ACCOUNT folder is the root — everything beside Documents (Teams Recordings, a
        // shared team folder) is inside the source now — and Documents is where panes open.
        #expect(oneDrive.rootPath == "/Users/test/Library/CloudStorage/OneDrive-Personal")
        #expect(oneDrive.openAt == "Documents")
        // The landing folder is exactly what this source's single path used to be. Every stored
        // absolute path in the app depends on that identity holding.
        #expect(oneDrive.landingPath == "/Users/test/Library/CloudStorage/OneDrive-Personal/Documents")
    }

    @Test func testGoogleDrivePrefixParsesAccountAndMyDriveDocumentsPath() throws {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("GoogleDrive-someone@gmail.com")],
            iCloudDefaultPath: iCloudDefault)

        let drive = try #require(providers.first(where: { $0.type == .googleDrive }))
        #expect(drive.id == "GoogleDrive-someone@gmail.com")
        #expect(drive.displayName == "Google Drive (someone@gmail.com)")
        #expect(drive.imageName == "googledrive")
        #expect(drive.rootPath == "/Users/test/Library/CloudStorage/GoogleDrive-someone@gmail.com")
        // Two components, so `My Drive` — the level a Drive account branches at, beside every
        // Shared drive — is an ordinary crumb rather than something the old root hid.
        #expect(drive.openAt == "My Drive/Documents")
        #expect(drive.landingPath == "/Users/test/Library/CloudStorage/GoogleDrive-someone@gmail.com/My Drive/Documents")
    }

    @Test func testDropboxRequiresExactNameAndUsesDocumentsPath() throws {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault)

        let dropbox = try #require(providers.first(where: { $0.type == .dropBox }))
        #expect(dropbox.id == "Dropbox")
        #expect(dropbox.displayName == "Dropbox")
        #expect(dropbox.imageName == "dropbox")
        #expect(dropbox.rootPath == "/Users/test/Library/CloudStorage/Dropbox")
        #expect(dropbox.openAt == "Documents")
        #expect(dropbox.landingPath == "/Users/test/Library/CloudStorage/Dropbox/Documents")
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
            iCloudDefaultPath: iCloudDefault)

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

        let accounts = SettingsManager.cloudStorageFolders(at: scanRoot)
        #expect(accounts.rootWasReadable)
        #expect(accounts.folders.map(\.lastPathComponent) == ["OneDrive-Personal"])
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
            iCloudDefaultPath: iCloudDefault)

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

    @Test func testRootOverrideReplacesOnlyTheMatchingProviderRoot() {
        let overrides = ["OneDrive-Personal": "/Volumes/External/OneDrive"]
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("OneDrive-Personal"), folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault, rootOverride: { overrides[$0] })

        #expect(providers.first(where: { $0.id == "OneDrive-Personal" })?.rootPath == "/Volumes/External/OneDrive")
        #expect(providers.first(where: { $0.id == "Dropbox" })?.rootPath == "/Users/test/Library/CloudStorage/Dropbox")
        #expect(providers.first(where: { $0.id == "iCloud" })?.rootPath == iCloudDefault)
    }

    @Test func testICloudRootOverrideBeatsTheDefaultPath() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [], iCloudDefaultPath: iCloudDefault,
            rootOverride: { $0 == "iCloud" ? "/Users/test/CustomDocs" : nil })

        #expect(providers.first(where: { $0.id == "iCloud" })?.rootPath == "/Users/test/CustomDocs")
    }

    @Test func testOpenAtOverrideReplacesOnlyTheMatchingProviderLandingFolder() {
        let overrides = ["OneDrive-Personal": "Teams Recordings"]
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("OneDrive-Personal"), folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault, openAtOverride: { overrides[$0] })

        let oneDrive = providers.first(where: { $0.id == "OneDrive-Personal" })
        #expect(oneDrive?.openAt == "Teams Recordings")
        // The root is untouched by a landing choice — the folder a pane opens at says nothing about
        // how far up it may go.
        #expect(oneDrive?.rootPath == "/Users/test/Library/CloudStorage/OneDrive-Personal")
        #expect(oneDrive?.landingPath == "/Users/test/Library/CloudStorage/OneDrive-Personal/Teams Recordings")
        #expect(providers.first(where: { $0.id == "Dropbox" })?.openAt == "Documents")
    }

    @Test func testAnEmptyOpenAtOverrideIsTheRootAndNotAnAbsentOne() {
        // "" is a real choice — open at the top of the account — and the only way a user can
        // express it. Treating it as "no override" (the shape `nameOverride` uses, where empty
        // restores the discovered default) would make that choice unrepresentable and silently
        // reinstate `Documents` on the next discovery pass.
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("OneDrive-Personal")],
            iCloudDefaultPath: iCloudDefault, openAtOverride: { $0 == "OneDrive-Personal" ? "" : nil })

        let oneDrive = providers.first(where: { $0.id == "OneDrive-Personal" })
        #expect(oneDrive?.openAt == "")
        #expect(oneDrive?.landingPath == "/Users/test/Library/CloudStorage/OneDrive-Personal")
    }

    @Test func testNameOverrideReplacesOnlyTheMatchingProviderName() {
        let names = [
            "GoogleDrive-someone@gmail.com": "Google Drive (Personal)",
            "Dropbox": "Dropbox (Work)",
        ]
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [folder("GoogleDrive-someone@gmail.com"), folder("OneDrive-Work"), folder("Dropbox")],
            iCloudDefaultPath: iCloudDefault,
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
            iCloudDefaultPath: iCloudDefault,
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
        test.defaults.set("/Volumes/External/OneDrive", forKey: "root_override_OneDrive-Personal")

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([folder("OneDrive-Personal"), folder("Dropbox")]) })
        await settings.discoverProviders()

        #expect(settings.availableProviders.map(\.id) == ["iCloud", "OneDrive-Personal", "Dropbox"])
        #expect(settings.rootPath(for: "OneDrive-Personal") == "/Volumes/External/OneDrive")
        #expect(settings.rootPath(for: "Dropbox") == "/Users/test/Library/CloudStorage/Dropbox")
    }

    @MainActor
    @Test func testSetPathResetPathRoundTripWithoutGlobalState() async {
        let test = TestDefaults()
        defer { test.wipe() }

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([folder("Dropbox")]) })
        await settings.discoverProviders()

        let defaultPath = settings.rootPath(for: "Dropbox")
        settings.setPath("/tmp/dropbox-elsewhere", for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.rootPath(for: "Dropbox") == "/tmp/dropbox-elsewhere")
        #expect(test.defaults.string(forKey: "root_override_Dropbox") == "/tmp/dropbox-elsewhere")

        settings.resetPath(for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.rootPath(for: "Dropbox") == defaultPath)
        #expect(test.defaults.string(forKey: "root_override_Dropbox") == nil)
    }

    @MainActor
    @Test func testSetCustomNameRoundTripAndClearRestoresDefaultName() async {
        let test = TestDefaults()
        defer { test.wipe() }

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([folder("GoogleDrive-someone@gmail.com")]) })
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

        let a = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })
        a.ignoreGoogleDriveNewerDateOnly = true // didSet persists
        // A fresh instance on the same suite reads the persisted value in init.
        #expect(SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) }).ignoreGoogleDriveNewerDateOnly == true)

        a.ignoreGoogleDriveNewerDateOnly = false
        #expect(SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) }).ignoreGoogleDriveNewerDateOnly == false)
    }

    @MainActor
    @Test func testAutoDiscoverFalseNeverListsAndExplicitDiscoveryListsOnce() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let counter = CallCounter()

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { counter.increment(); return .read([]) })
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
            cloudStorageLister: { .read(lister.list()) })

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
            cloudStorageLister: { .read([folder("Dropbox")]) })
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
            cloudStorageLister: { .read([folder("Dropbox")]) },
            pathValidator: { _ in counter.increment(); return true })

        await settings.discoverProviders()
        let providersAfterFirst = settings.availableProviders.map(\.id)
        let validationsAfterFirst = counter.count
        // One stat per source, plus a second for each that lands somewhere other than its own
        // root — a landing folder is a separate question from the root, and asking it is the point
        // of `landingValidity`. Derived rather than written as a number so the pin stays about
        // "every pass re-checks the disk" rather than about how many sources the fixture has.
        let statsPerPass = settings.availableProviders.reduce(0) { $0 + ($1.openAt.isEmpty ? 1 : 2) }
        #expect(validationsAfterFirst >= providersAfterFirst.count)

        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id) == providersAfterFirst)
        #expect(counter.count == validationsAfterFirst + statsPerPass)
    }
}
