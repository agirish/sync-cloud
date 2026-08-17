import Testing
import Foundation
@testable import Settings

/// Provider discovery must not report "you have no cloud accounts" when what actually happened is
/// "I could not read the folder they live in".
///
/// `discoverProviders` **publishes over** `availableProviders`, so an empty answer from a failed
/// listing does not merely go unnoticed — it removes every Dropbox / Google Drive / OneDrive the
/// user has, and leaves the always-present iCloud entry behind to make the result look plausible.
/// The `if let enumerator = …` that used to guard this had an else-branch the filesystem never
/// reaches: `FileManager.enumerator(at:)` is non-nil for a directory it cannot list.
@Suite struct CloudStorageRootReadabilityTests {

    // MARK: The lister, against a real directory

    private func makeRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudroot-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aRootWithAccountsInItListsThem() throws {
        let root = try makeRoot("normal"); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Dropbox", "OneDrive-Personal"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        let accounts = SettingsManager.cloudStorageFolders(at: root)
        #expect(accounts.rootWasReadable)
        #expect(accounts.folders.map(\.lastPathComponent).sorted() == ["Dropbox", "OneDrive-Personal"])
    }

    @Test func anEmptyRootIsAnHonestEmptyAnswer() throws {
        let root = try makeRoot("empty"); defer { try? FileManager.default.removeItem(at: root) }
        let accounts = SettingsManager.cloudStorageFolders(at: root)
        #expect(accounts.folders.isEmpty)
        // Readable and empty: the user really has no accounts mounted, and discovery should act on it.
        #expect(accounts.rootWasReadable)
    }

    @Test func anAbsentRootIsAlsoAnHonestEmptyAnswer() throws {
        // A Mac that has never mounted a cloud account has no ~/Library/CloudStorage at all. This is
        // why the root is stat'ed before it is listed: the enumerator's error handler fires for a
        // MISSING directory exactly as it does for an unreadable one (measured: NSFileNoSuchFileError
        // 260 vs NSFileReadNoPermissionError 257), so keying off the handler alone would report a
        // failure on every such Mac.
        let root = try makeRoot("absent")
        try FileManager.default.removeItem(at: root)
        let accounts = SettingsManager.cloudStorageFolders(at: root)
        #expect(accounts.folders.isEmpty)
        #expect(accounts.rootWasReadable)
    }

    @Test func anUnreadableRootIsNotAnEmptyAnswer() throws {
        let root = try makeRoot("locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        // Real accounts are in there — the whole point is that the listing cannot see them.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Dropbox"),
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        // The fixture is only meaningful if the directory really did become unlistable here; a
        // process that could still read it would make every assertion below pass vacuously.
        try #require((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == nil)

        let accounts = SettingsManager.cloudStorageFolders(at: root)
        #expect(!accounts.rootWasReadable)
        #expect(accounts.folders.isEmpty)   // empty, and carrying no claim that there are none
    }

    // MARK: Discovery, which publishes over the list

    @MainActor
    @Test func anUnreadableRootDoesNotDeleteTheAccountsAlreadyFound() async {
        let test = TestDefaults(); defer { test.wipe() }
        let readable = Mutable(true)
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: {
                readable.value
                    ? .read([URL(fileURLWithPath: "/CloudStorage/Dropbox"),
                             URL(fileURLWithPath: "/CloudStorage/OneDrive-Personal")])
                    : .unreadableRoot
            },
            pathValidator: { _ in true })

        await settings.discoverProviders()
        let found = settings.availableProviders.map(\.id)
        #expect(found.contains("Dropbox"))
        #expect(found.contains("OneDrive-Personal"))

        // The CloudStorage folder becomes unreadable. Discovery learns nothing — it must not
        // conclude the accounts are gone.
        readable.value = false
        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id) == found)
    }

    @MainActor
    @Test func aReadableRootWithNothingInItStillRemovesTheAccounts() async {
        // The other direction, and the one that decides whether the guard above is a fix or an
        // outage: a user who really does unlink every account must see them go. Only an UNREADABLE
        // root is refused, and a root that lost its accounts is readable and empty.
        let test = TestDefaults(); defer { test.wipe() }
        let mounted = Mutable(true)
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: {
                mounted.value ? .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) : .read([])
            },
            pathValidator: { _ in true })

        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id).contains("Dropbox"))

        mounted.value = false
        await settings.discoverProviders()
        #expect(!settings.availableProviders.map(\.id).contains("Dropbox"))
        // iCloud is synthesized rather than discovered, so it stays — that is what makes a
        // truncated list look plausible, and why the guard above matters.
        #expect(settings.availableProviders.map(\.id) == ["iCloud"])
    }
}

/// One mutable value reachable from the `@Sendable` lister closure.
private final class Mutable<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
