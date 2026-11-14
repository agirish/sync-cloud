import Testing
import Foundation
@testable import Settings
import Sync

/// The landing folder a source opens panes at: choosing one, refusing one, clearing one, and
/// degrading when the chosen folder stops existing. `SettingsDiscoveryTests` covers what
/// `landingPath` composes to; this covers what happens when a user picks a folder.
///
/// Real directories throughout, because two branches are about the filesystem: the symlink
/// fallback is for what `NSOpenPanel` hands back on a firmlinked home directory, and the degrade is
/// for a folder renamed out from under a stored preference.
@MainActor
struct OpenAtTests {

    /// A root with `Documents/Reports` inside it, plus a sibling the root does not contain.
    struct Tree {
        let base: URL
        var root: URL { base.appendingPathComponent("Account") }
        var documents: URL { root.appendingPathComponent("Documents") }
        var reports: URL { documents.appendingPathComponent("Reports") }
        var outside: URL { base.appendingPathComponent("Elsewhere") }

        init() throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("OpenAtTests-\(UUID().uuidString)")
            for url in [reports, outside] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        func wipe() { try? FileManager.default.removeItem(at: base) }
    }

    /// A manager holding one folder-shaped source rooted at `tree.root`, with any stored `openAt`
    /// override applied, as discovery does.
    static func manager(_ test: TestDefaults, _ tree: Tree,
                        validator: @escaping @Sendable (String) -> Bool = { _ in true })
    -> SettingsManager {
        let manager = test.manager(validator: validator, domain: test.suiteName)
        manager.availableProviders = [
            CloudProvider(id: "Acct", displayName: "Acct", imageName: "cloud",
                          rootPath: tree.root.path,
                          openAt: test.defaults.string(
                            forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") ?? "Documents",
                          type: .oneDrive)
        ]
        return manager
    }

    @Test("A folder inside the root is stored relative to it")
    func aChoiceInsideTheRootIsStoredRelative() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(manager.setOpenAt(tree.reports.path, for: "Acct") == .changed)
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct")
            == "Documents/Reports")
    }

    @Test("Picking the root itself stores the empty string, rather than clearing the choice")
    func theRootIsAStoredChoiceAndNotAnAbsentOne() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(manager.setOpenAt(tree.root.path, for: "Acct") == .changed)
        // `""` is a real landing folder, the top of the account; an absent key means the
        // discovered default (`Documents` here). Storing nothing would undo the user's choice.
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == "")
        #expect(manager.hasOpenAtOverride(for: "Acct"))
    }

    @Test("A folder outside the root is refused, and nothing is written")
    func aChoiceOutsideTheRootIsRefused() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        // Its own case, not `.refusedDuplicate(existingId:)`, which would read as "that folder
        // already belongs to this source".
        #expect(manager.setOpenAt(tree.outside.path, for: "Acct") == .refusedOutsideRoot)
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == nil)
    }

    @Test("A folder reached through a symlink into the root is accepted, keeping its own spelling")
    func aChoiceReachedThroughALinkIsInsideTheRoot() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        let link = tree.base.appendingPathComponent("LinkToAccount")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.root)
        let manager = Self.manager(test, tree)

        let through = link.appendingPathComponent("Documents/Reports").path
        #expect(manager.setOpenAt(through, for: "Acct") == .changed)
        // Resolved only for the containment check: the stored value is still measured from the
        // source's own root.
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct")
            == "Documents/Reports")
    }

    @Test("A source with no root refuses rather than reporting success")
    func anUnknownSourceRefusesAudibly() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        // The picker reads `.unchanged` as success, so returning it for a source dropped while its
        // row is on screen would lose the pick with no word on screen or in the log.
        #expect(manager.setOpenAt(tree.reports.path, for: "NotDiscovered") == .refusedUnknownSource)
    }

    /// A manager that has run a discovery pass over `account` as a CloudStorage account, so
    /// `landingValidity` holds a measured answer. The degrade fires only on positive evidence of
    /// absence, which assigning `availableProviders` directly never produces.
    static func discoveredManager(_ test: TestDefaults, _ account: URL,
                                  validator: @escaping @Sendable (String) -> Bool) async
    -> SettingsManager {
        let manager = test.manager(lister: { .read([account]) }, validator: validator, domain: test.suiteName)
        await manager.discoverProviders()
        return manager
    }

    @Test("A landing folder that is gone degrades to the root, and the choice is kept")
    func anUnreachableLandingFolderOpensAtTheRoot() async throws {
        let test = TestDefaults()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenAtDegrade-\(UUID().uuidString)")
        let account = base.appendingPathComponent("OneDrive-Acct")
        let landing = account.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Everything exists except the landing folder, as after renaming it in Finder.
        let manager = await Self.discoveredManager(test, account, validator: { $0 != landing.path })

        #expect(manager.openAtIfReachable(for: "OneDrive-Acct") == "")
        #expect(manager.landingPath(for: "OneDrive-Acct") == account.path)
        // The degrade keeps the stored preference: the folder may come back, and rewriting it here
        // would destroy the choice on the first bad read.
        #expect(manager.openAt(for: "OneDrive-Acct") == "Documents")
        // The row that explains it has both halves of its evidence: root there, landing not.
        #expect(manager.isPathValid(for: "OneDrive-Acct"))
        #expect(!manager.isLandingValid(for: "OneDrive-Acct"))
    }

    @Test("A source published before the pass that measures it still opens at its landing folder")
    func anUnmeasuredSourceIsNotTreatedAsMissing() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        test.defaults.set("Documents/Reports",
                          forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct")
        // `availableProviders` with no validity pass behind it: the launch window between discovery
        // publishing the list and the off-main pass that stats it.
        let manager = Self.manager(test, tree)

        // The degrade fires on evidence of absence, never on absence of evidence: reading "no
        // entry" as "gone" would seed every pane at the account root in the very window when a
        // wrong folder gets saved back as the last-open one.
        #expect(manager.openAtIfReachable(for: "Acct") == "Documents/Reports")
        #expect(manager.landingPath(for: "Acct") == tree.reports.path)
        // The Settings row warns only on positive evidence about the root, so it says nothing here
        // and the two readers' opposite defaults never contradict on screen.
        #expect(!manager.isPathValid(for: "Acct"))
    }

    @Test("Reset clears a chosen landing folder, and does nothing when there is none")
    func resetOnlyActsWhenThereIsSomethingToReset() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(!manager.hasOpenAtOverride(for: "Acct"))
        manager.resetOpenAt(for: "Acct")
        #expect(!manager.hasOpenAtOverride(for: "Acct"))

        manager.setOpenAtRelative("Documents/Reports", for: "Acct")
        #expect(manager.hasOpenAtOverride(for: "Acct"))
        manager.resetOpenAt(for: "Acct")
        // Removed, not set to the default: an absent key lets discovery supply the per-type default,
        // so writing `Documents` would re-pin what Reset undoes.
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == nil)
    }

    @Test("A root override is visible to the row that has to offer a way out of it")
    func aRootOverrideIsReportedAndClearable() throws {
        let test = TestDefaults()
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(!manager.hasRootOverride(for: "Acct"))
        // Only `RootsMigration` writes this, for a legacy Location outside the account. Settings
        // must report it and offer a way to clear it, since nothing else touches the key.
        test.defaults.set("/Volumes/Backup/Work",
                          forKey: SettingsManager.rootOverrideKeyPrefix + "Acct")
        #expect(manager.hasRootOverride(for: "Acct"))

        manager.setPath("", for: "Acct")
        #expect(!manager.hasRootOverride(for: "Acct"))
    }

    /// The "Choose…" panel opens at the folder panes actually open at, not at the stored one. A
    /// source scan, because `NSOpenPanel` can't be started from a test and the claim is about which
    /// expression seeds `panel.directoryURL`.
    ///
    /// `provider.landingPath` joins root and `openAt` unconditionally; `settings.landingPath(for:)`
    /// degrades to the root when that folder is gone. Seeded from the first, the panel opens on a
    /// missing path, macOS drops the user wherever it last was, likely outside this root, and their
    /// first pick is refused by the containment rule. `SetupSheet.seedWalkRoot` has the same rule.
    @Test("The landing-folder picker is seeded through the manager, not through the value type")
    func theOpenAtPanelIsSeededFromTheReachableLanding() throws {
        let source = try settingsSource("SettingsView.swift")
        let start = try #require(source.range(of: "private func selectOpenAtDirectory() {"),
                                 "cannot find selectOpenAtDirectory — this test is checking a name that no longer exists")
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "\n    }"), "cannot find the end of selectOpenAtDirectory")
        // Comments stripped first: the function names `provider.landingPath` in prose to say what
        // it doesn't do, and a raw scan would fail on that mention.
        let body = SourceComments.stripped(String(tail[..<end.lowerBound]))

        #expect(body.contains("settings.landingPath(for: provider.id)"),
                "the panel is seeded from somewhere other than the manager's reachable landing folder")
        #expect(!body.contains("provider.landingPath"),
                "the panel is seeded from the value type's unconditional join, which can name a folder that is gone")
    }
}
