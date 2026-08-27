import Testing
import Foundation
@testable import Settings
import Sync

/// The landing folder a source opens panes at: choosing one, refusing one, clearing one, and
/// degrading when the chosen folder stops existing.
///
/// This is the only genuinely new decision logic the roots split added to `SettingsManager`, and it
/// shipped with none of its own coverage — `SettingsDiscoveryTests` asserts what `landingPath`
/// composes to, which is a different question from what happens when a user picks a folder.
///
/// Real directories throughout, because two of the four branches are about the filesystem: the
/// symlink fallback exists for what `NSOpenPanel` hands back on a firmlinked home directory, and
/// the degrade exists for a folder that was renamed out from under a stored preference.
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

    /// A manager holding one folder-shaped source rooted at `tree.root`, with whatever `openAt`
    /// override is on disk applied — the same composition discovery performs.
    static func manager(_ test: TestDefaults, _ tree: Tree,
                        validator: @escaping @Sendable (String) -> Bool = { _ in true })
    -> SettingsManager {
        let manager = SettingsManager(autoDiscover: false, userDefaults: test.defaults,
                                      overridesDomainName: test.suiteName,
                                      cloudStorageLister: { .read([]) },
                                      pathValidator: validator)
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
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(manager.setOpenAt(tree.reports.path, for: "Acct") == .changed)
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct")
            == "Documents/Reports")
    }

    @Test("Picking the root itself stores the empty string, rather than clearing the choice")
    func theRootIsAStoredChoiceAndNotAnAbsentOne() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(manager.setOpenAt(tree.root.path, for: "Acct") == .changed)
        // `""` is a real landing folder — "open at the top of the account" — and an ABSENT key means
        // "use the discovered default", which for this source is `Documents`. Storing nothing here
        // would silently put the user back where they navigated away from.
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == "")
        #expect(manager.hasOpenAtOverride(for: "Acct"))
    }

    @Test("A folder outside the root is refused, and nothing is written")
    func aChoiceOutsideTheRootIsRefused() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        // Its own case. It used to borrow `.refusedDuplicate(existingId:)` and pass the asking
        // source's own id, which reads as "that folder is already this very source's folder".
        #expect(manager.setOpenAt(tree.outside.path, for: "Acct") == .refusedOutsideRoot)
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == nil)
    }

    @Test("A folder reached through a symlink into the root is accepted, keeping its own spelling")
    func aChoiceReachedThroughALinkIsInsideTheRoot() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        let link = tree.base.appendingPathComponent("LinkToAccount")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.root)
        let manager = Self.manager(test, tree)

        let through = link.appendingPathComponent("Documents/Reports").path
        #expect(manager.setOpenAt(through, for: "Acct") == .changed)
        // Resolved for the TEST only: a folder reached through a link is genuinely inside the root
        // it resolves into, and the stored value is still measured from the root the source has.
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct")
            == "Documents/Reports")
    }

    @Test("A source with no root refuses rather than reporting success")
    func anUnknownSourceRefusesAudibly() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        // `.unchanged` is what the picker reads as success, so this returned "fine" for a source
        // that had been dropped from the list while its row was on screen: the panel closed, the
        // pick vanished, and nothing on screen or in the log said why.
        #expect(manager.setOpenAt(tree.reports.path, for: "NotDiscovered") == .refusedUnknownSource)
    }

    /// A manager that has actually RUN a discovery pass over `tree.root` as a CloudStorage account,
    /// so `landingValidity` holds a measured answer rather than nothing.
    ///
    /// The degrade fires on positive evidence of absence, so a test that assigns `availableProviders`
    /// directly cannot reach it at all — it would assert against the pre-measurement window instead
    /// and pass for the wrong reason.
    static func discoveredManager(_ test: TestDefaults, _ account: URL,
                                  validator: @escaping @Sendable (String) -> Bool) async
    -> SettingsManager {
        let manager = SettingsManager(autoDiscover: false, userDefaults: test.defaults,
                                      overridesDomainName: test.suiteName,
                                      cloudStorageLister: { .read([account]) },
                                      pathValidator: validator)
        await manager.discoverProviders()
        return manager
    }

    @Test("A landing folder that is gone degrades to the root, and the choice is kept")
    func anUnreachableLandingFolderOpensAtTheRoot() async throws {
        let test = TestDefaults(); defer { test.wipe() }
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenAtDegrade-\(UUID().uuidString)")
        let account = base.appendingPathComponent("OneDrive-Acct")
        let landing = account.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Everything exists except the landing folder — the shape left behind by renaming it in
        // Finder, which is the state this degrade is for.
        let manager = await Self.discoveredManager(test, account, validator: { $0 != landing.path })

        #expect(manager.openAtIfReachable(for: "OneDrive-Acct") == "")
        #expect(manager.landingPath(for: "OneDrive-Acct") == account.path)
        // The stored preference is NOT cleared by the degrade: the folder may come back, and a
        // reader that rewrote it here would destroy the choice on the first bad read.
        #expect(manager.openAt(for: "OneDrive-Acct") == "Documents")
        // And the row that explains it has both halves of its evidence — root there, landing not.
        #expect(manager.isPathValid(for: "OneDrive-Acct"))
        #expect(!manager.isLandingValid(for: "OneDrive-Acct"))
    }

    @Test("A source published before the pass that measures it still opens at its landing folder")
    func anUnmeasuredSourceIsNotTreatedAsMissing() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        test.defaults.set("Documents/Reports",
                          forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct")
        // `availableProviders` assigned with no validity pass behind it — the launch window between
        // discovery publishing the list and the off-main pass that stats it.
        let manager = Self.manager(test, tree)

        // The degrade must fire on positive evidence of ABSENCE, never on the absence of evidence:
        // reading "no entry" as "gone" seeds every pane at the account root for that window, which
        // is exactly when a wrong folder gets saved back as the last-open one.
        #expect(manager.openAtIfReachable(for: "Acct") == "Documents/Reports")
        #expect(manager.landingPath(for: "Acct") == tree.reports.path)
        // And the Settings row says nothing, because it warns only when it also has positive
        // evidence about the root — so the two readers' opposite defaults never contradict on screen.
        #expect(!manager.isPathValid(for: "Acct"))
    }

    @Test("Reset clears a chosen landing folder, and does nothing when there is none")
    func resetOnlyActsWhenThereIsSomethingToReset() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(!manager.hasOpenAtOverride(for: "Acct"))
        manager.resetOpenAt(for: "Acct")
        #expect(!manager.hasOpenAtOverride(for: "Acct"))

        manager.setOpenAtRelative("Documents/Reports", for: "Acct")
        #expect(manager.hasOpenAtOverride(for: "Acct"))
        manager.resetOpenAt(for: "Acct")
        // Removed, not set to the default: an absent key is what makes discovery supply the
        // per-type default, so writing `Documents` here would re-pin the very thing Reset undoes.
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == nil)
    }

    @Test("A root override is visible to the row that has to offer a way out of it")
    func aRootOverrideIsReportedAndClearable() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let tree = try Tree(); defer { tree.wipe() }
        let manager = Self.manager(test, tree)

        #expect(!manager.hasRootOverride(for: "Acct"))
        // Only `RootsMigration` writes this in production, for a legacy Location outside the
        // account. With no reader, Settings showed it as the account's one true root and offered
        // nothing to clear it — permanent, since nothing else touches the key.
        test.defaults.set("/Volumes/Backup/Work",
                          forKey: SettingsManager.rootOverrideKeyPrefix + "Acct")
        #expect(manager.hasRootOverride(for: "Acct"))

        manager.setPath("", for: "Acct")
        #expect(!manager.hasRootOverride(for: "Acct"))
    }
}
