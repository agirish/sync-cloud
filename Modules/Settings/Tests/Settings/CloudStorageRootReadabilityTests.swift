import Testing
import Foundation
@testable import Settings
import Sync

/// Provider discovery must not report "no cloud accounts" when it could not read the folder they
/// live in.
///
/// `discoverProviders` publishes over `availableProviders`, so an empty answer from a failed
/// listing would remove every Dropbox, Google Drive and OneDrive account, leaving iCloud behind
/// to look plausible. `FileManager.enumerator(at:)` is non-nil even for a directory it can't list,
/// so a nil check can't catch this.
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
        // A Mac that never mounted a cloud account has no ~/Library/CloudStorage. The root is
        // stat'ed before listing because the enumerator's error handler fires for a missing
        // directory just as for an unreadable one, so the handler alone would report a failure on
        // every such Mac.
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
        // Real accounts are in there; the point is that the listing can't see them.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Dropbox"),
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        // The directory must really be unlistable, or every check below passes vacuously.
        try #require((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == nil)

        let accounts = SettingsManager.cloudStorageFolders(at: root)
        #expect(!accounts.rootWasReadable)
        #expect(accounts.folders.isEmpty)   // empty, and carrying no claim that there are none
    }

    // MARK: Discovery, which publishes over the list

    @MainActor
    @Test func anUnreadableRootDoesNotDeleteTheAccountsAlreadyFound() async {
        let test = TestDefaults()
        let readable = Mutable(true)
        let settings = test.manager(
            lister: {
                readable.value
                    ? .read([URL(fileURLWithPath: "/CloudStorage/Dropbox"),
                             URL(fileURLWithPath: "/CloudStorage/OneDrive-Personal")])
                    : .unreadableRoot
            },
            validator: { _ in true })

        await settings.discoverProviders()
        let found = settings.availableProviders.map(\.id)
        #expect(found.contains("Dropbox"))
        #expect(found.contains("OneDrive-Personal"))

        // The CloudStorage folder becomes unreadable. Discovery learns nothing, so it must not
        // conclude the accounts are gone.
        readable.value = false
        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id) == found)
    }

    @MainActor
    @Test func aReadableRootWithNothingInItStillRemovesTheAccounts() async {
        // The other direction: a user who unlinks every account must see them go. Only an
        // unreadable root is refused; a root that lost its accounts is readable and empty.
        let test = TestDefaults()
        let mounted = Mutable(true)
        let settings = test.manager(
            lister: {
                mounted.value ? .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) : .read([])
            },
            validator: { _ in true })

        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id).contains("Dropbox"))

        mounted.value = false
        await settings.discoverProviders()
        #expect(!settings.availableProviders.map(\.id).contains("Dropbox"))
        // iCloud is synthesized, not discovered, so it stays; that is what makes a truncated list
        // look plausible.
        #expect(settings.availableProviders.map(\.id) == ["iCloud"])
    }

    @MainActor
    @Test func anUnreadableRootStillPublishesEverythingItDidLearn() async {
        // The failure is confined to what the listing is evidence about. A pass that can't read the
        // root still re-stats every provider's path, and that must reach the UI, or a deleted
        // folder keeps a valid badge for as long as the root stays unreadable.
        let test = TestDefaults()
        let readable = Mutable(true)
        let dropboxIsValid = Mutable(true)
        let settings = test.manager(
            lister: {
                readable.value ? .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) : .unreadableRoot
            },
            validator: { path in path.contains("Dropbox") ? dropboxIsValid.value : true })

        await settings.discoverProviders()
        #expect(settings.pathValidity["Dropbox"] == true)

        // The root becomes unreadable AND Dropbox's own folder goes away.
        readable.value = false
        dropboxIsValid.value = false
        await settings.discoverProviders()

        // Still listed: the unreadable root is no evidence the account is gone …
        #expect(settings.availableProviders.map(\.id).contains("Dropbox"))
        // … and what the pass did establish is published, not discarded.
        #expect(settings.pathValidity["Dropbox"] == false,
                "a stale validity badge outlived the pass that disproved it")
    }

    @MainActor
    @Test func addingAFolderSourceWhileTheRootIsUnreadableKeepsTheAccountsToo() async {
        // A provider count can't see this case: `availableProviders` holds folder sources too, so
        // losing an account while gaining a folder source leaves the count unchanged.
        // `addFolderSource` calls `discoverProviders()` itself, so this is the ordinary sequence.
        let test = TestDefaults()
        let readable = Mutable(true)
        let settings = test.manager(
            lister: {
                readable.value ? .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) : .unreadableRoot
            },
            validator: { _ in true })

        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id) == ["iCloud", "Dropbox"])

        readable.value = false
        _ = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        let ids = settings.availableProviders.map(\.id)
        #expect(ids.contains("Dropbox"), "the account was dropped while the root was unreadable: \(ids)")
        #expect(ids.contains(where: { FolderSource.isFolderSourceId($0) }),
                "the folder source the user just added is missing: \(ids)")
    }

    @MainActor
    @Test func removingAFolderSourceWhileTheRootIsUnreadableStillTakesEffect() async {
        // The other direction: a count rule would refuse this legitimate shrink.
        let test = TestDefaults()
        let readable = Mutable(true)
        let settings = test.manager(
            lister: {
                readable.value ? .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) : .unreadableRoot
            },
            validator: { _ in true })
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()
        #expect(settings.availableProviders.map(\.id).contains(id))

        readable.value = false
        settings.removeFolderSource(id: id)
        await settings.discoverProviders()

        let ids = settings.availableProviders.map(\.id)
        #expect(!ids.contains(id), "the removed folder source came back: \(ids)")
        #expect(ids.contains("Dropbox"), "and the account must still be there: \(ids)")
    }
}
