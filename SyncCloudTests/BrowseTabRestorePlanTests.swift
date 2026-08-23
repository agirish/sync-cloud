import Testing
import Foundation
@testable import SyncCloud
import Sync

/// Executes every branch of the launch restore's decision — the branches that were previously
/// pinned only as source text (`PaneTabWiringTests` scanned the function body for its literals and
/// their relative order, because a `View` extension cannot be instantiated). The store half is
/// covered in `Modules/Sync` (`PaneTabsTests`); this suite owns the account the host gives of it:
/// which lines are said, in what order, what is installed, and when the pane adopts a provider.
@MainActor
@Suite struct BrowseTabRestorePlanTests {

    private func entry(_ providerId: String = "iCloud", path: String = "Docs/Tax",
                       stackDepth: Int = 0, pinned: Bool = false) -> PaneTabsStore.Entry {
        PaneTabsStore.Entry(providerId: providerId, relativePath: path,
                            stackDepth: stackDepth, pinned: pinned)
    }

    private func plan(entries: [PaneTabsStore.Entry], selected: Int = 0,
                      isLeft: Bool = true,
                      currentProviderId: String = "iCloud",
                      known: Set<String> = ["iCloud", "Dropbox"],
                      folderExists: @escaping (String, String) -> Bool = { _, _ in true })
        -> BrowseTabRestorePlan.Plan {
        let outcome = PaneTabsStore.restore(entries: entries, selected: selected,
                                            isKnownProvider: { known.contains($0) },
                                            folderExists: folderExists)
        return BrowseTabRestorePlan.plan(storedCount: entries.count, outcome: outcome,
                                         isLeft: isLeft, currentProviderId: currentProviderId,
                                         canShowSource: { known.contains($0) })
    }

    // MARK: The ordinary launch

    @Test func aHealthyStripInstallsAndSaysHowManyCameBack() throws {
        let p = plan(entries: [entry(path: "Docs"), entry(path: "Docs/Tax"), entry(path: "")],
                     selected: 1)
        let installed = try #require(p.install)
        #expect(installed.count == 3)
        #expect(installed.active.relativePath == "Docs/Tax",
                "the stored selection survives as the active tab")
        #expect(p.lines == [.init(level: .info, message: "Restored 3 left browse tabs")])
        #expect(p.adoptProviderId == nil, "the pane is already on the active tab's source")
    }

    /// The singular/plural and side vocabulary, which a Compare launch needs to tell its panes
    /// apart — dropping the side from these lines once left a two-pane launch unable to say which
    /// pane lost what.
    @Test func theLinesNameTheSideAndCountHonestly() throws {
        let right = plan(entries: [entry(path: "Docs"), entry(path: "")], isLeft: false)
        #expect(right.lines == [.init(level: .info, message: "Restored 2 right browse tabs")])
        let single = plan(entries: [entry(path: "Docs"), entry(path: "Docs/B")], isLeft: false,
                          known: ["iCloud"], folderExists: { _, _ in true })
        #expect(single.lines.last?.message == "Restored 2 right browse tabs")
    }

    // MARK: Drops (source gone or switched off)

    @Test func droppedSourcesAreCountedBeforeAnythingElseIsSaid() throws {
        let p = plan(entries: [entry("Gone", path: "X"), entry("AlsoGone", path: "Y"),
                               entry(path: "Docs"), entry(path: "Docs/Tax")],
                     selected: 2, known: ["iCloud"])
        #expect(p.lines.first == .init(
            level: .warning,
            message: "Dropped 2 stored left browse tabs: their source is gone or switched off"))
        #expect(p.install?.count == 2)
    }

    @Test func aWhollyDroppedStripWarnsAndInstallsNothing() {
        let p = plan(entries: [entry("Gone", path: "X")], known: ["iCloud"])
        #expect(p.install == nil)
        #expect(p.lines == [.init(
            level: .warning,
            message: "Dropped 1 stored left browse tab: their source is gone or switched off")])
    }

    // MARK: The seed-state abandon

    /// A fresh install's own state — one tab at the root — must not be re-installed under new ids.
    @Test func theSeedStateIsLeftAloneInSilence() {
        let p = plan(entries: [entry(path: "")])
        #expect(p.install == nil)
        #expect(p.lines.isEmpty)
    }

    /// The one launch where the "at its source root" sentence would be both the most alarming and
    /// the most wrong: a one-entry strip whose only folder is gone re-roots to exactly the seed
    /// state, so nothing is installed — and the truthful line replaces the claim of a restore.
    @Test func anAbandonedRestoreNamesTheLostFolderWithoutClaimingARestore() {
        let p = plan(entries: [entry(path: "Docs/Tax")], folderExists: { _, _ in false })
        #expect(p.install == nil)
        #expect(p.lines == [.init(
            level: .warning,
            message: "Did not restore the left browse tab “Docs/Tax”: its folder no longer exists, "
                + "and one tab at a source root is the state a fresh launch already seeds")])
        #expect(!p.lines.contains { $0.message.contains("at its source root") },
                "the abandoned launch must not claim a tab came back")
    }

    /// Both misfortunes at once: one entry's SOURCE is gone (dropped) and the survivor's FOLDER is
    /// gone (re-rooted to seed state → abandoned). The dropped warning still leads, the abandoned
    /// line still replaces the restore claims, nothing installs — the combination neither
    /// single-misfortune test above can see.
    @Test func aDroppedSourceAndALostFolderTogetherWarnTwiceAndInstallNothing() {
        let p = plan(entries: [entry("Gone", path: "Old/Stuff"), entry(path: "Docs/Tax")],
                     selected: 1,
                     folderExists: { _, _ in false })
        #expect(p.install == nil)
        #expect(p.lines.map(\.level) == [.warning, .warning])
        #expect(p.lines.first?.message.hasPrefix("Dropped 1 stored left browse tab") == true,
                "what the restore threw away is still said first — got \(p.lines)")
        #expect(p.lines.last?.message.hasPrefix("Did not restore the left browse tab “Docs/Tax”") == true)
        #expect(!p.lines.contains { $0.message.contains("Restored") })
    }

    /// The pairing invariant the executor leans on: `adoptProviderId` and `adoptLog` are one
    /// decision — the host logs `plan.adoptLog ?? ""` beside the adopt, so an id without its
    /// audit line would write an EMPTY line into the log he audits, and a line without its id
    /// would be an audit of nothing.
    @Test func adoptionAndItsAuditLineAlwaysTravelTogether() {
        let adopting = plan(entries: [entry("Dropbox", path: "Work")], currentProviderId: "iCloud")
        #expect((adopting.adoptProviderId == nil) == (adopting.adoptLog == nil))
        #expect(adopting.adoptLog?.isEmpty == false)

        let staying = plan(entries: [entry(path: "Docs/Tax")])
        #expect((staying.adoptProviderId == nil) == (staying.adoptLog == nil))
    }

    // MARK: Re-rooted folders

    /// A tab whose folder is gone comes back at its source root — deliberately — and the stored
    /// path is the last place that folder is named, so the plan names it, before the restored
    /// count that would otherwise read as "nothing was lost".
    @Test func aReRootedTabsFolderIsNamedBeforeTheRestoredCount() throws {
        let p = plan(entries: [entry(path: "Docs/Gone"), entry(path: "Docs")],
                     folderExists: { _, path in path != "Docs/Gone" })
        #expect(p.lines == [
            .init(level: .warning,
                  message: "Restored the left browse tab “Docs/Gone” at its source root: the folder no longer exists"),
            .init(level: .info, message: "Restored 2 left browse tabs"),
        ])
        #expect(p.install?.count == 2)
    }

    // MARK: Provider adoption

    @Test func anActiveTabOnAnotherSourceAsksForAdoptionWithItsAuditLine() throws {
        let p = plan(entries: [entry("Dropbox", path: "Work")], currentProviderId: "iCloud")
        #expect(p.adoptProviderId == "Dropbox")
        #expect(p.adoptLog == "Restored left browse tab moved the pane to Dropbox")
    }

    /// `canShowSource` is consulted even though `restore` already filtered — the pane's list can
    /// narrow between the two calls, and adopting a source the pane cannot show would strand it.
    @Test func adoptionIsWithheldWhenThePaneCannotShowTheSource() throws {
        let outcome = PaneTabsStore.restore(entries: [entry("Dropbox", path: "Work")], selected: 0,
                                            isKnownProvider: { _ in true },
                                            folderExists: { _, _ in true })
        let p = BrowseTabRestorePlan.plan(storedCount: 1, outcome: outcome, isLeft: true,
                                          currentProviderId: "iCloud",
                                          canShowSource: { _ in false })
        #expect(p.install != nil)
        #expect(p.adoptProviderId == nil)
    }

    // MARK: A hand-authored stored payload, end to end

    /// The pipeline from bytes: a strip as a v4.2 build wrote it (JSON string under the pane's
    /// key, `stackDepth`/`pinned` present), through `load` → `restore` → `plan`. No other MacApp
    /// test starts from persisted bytes — every prior tab test either scanned source or exercised
    /// values it had just built.
    @Test func aStoredV42StripRestoresFromItsRawBytes() throws {
        let test = TestDefaults()
        defer { test.wipe() }
        let raw = """
        [{"providerId":"iCloud","relativePath":"Documents/Taxes/2025","stackDepth":1,"pinned":true},
         {"providerId":"iCloud","relativePath":"Desktop","stackDepth":0,"pinned":false},
         {"providerId":"Dropbox","relativePath":"Shared/Specs","stackDepth":2,"pinned":false}]
        """
        test.defaults.set(raw, forKey: PaneTabsStore.tabsKey)
        test.defaults.set(2, forKey: PaneTabsStore.selectedKey)

        let stored = try #require(PaneTabsStore.load(isLeft: true, from: test.defaults))
        let outcome = PaneTabsStore.restore(entries: stored.entries, selected: stored.selected,
                                            isKnownProvider: { ["iCloud", "Dropbox"].contains($0) },
                                            folderExists: { _, _ in true })
        let p = BrowseTabRestorePlan.plan(storedCount: stored.entries.count, outcome: outcome,
                                          isLeft: true, currentProviderId: "iCloud",
                                          canShowSource: { ["iCloud", "Dropbox"].contains($0) })

        let installed = try #require(p.install)
        #expect(installed.count == 3)
        // The selected entry survives as the active tab, and its provider drives adoption.
        #expect(installed.active.providerId == "Dropbox")
        #expect(p.adoptProviderId == "Dropbox")
        // The stored depth is not flattened: two components of Shared/Specs are the column stack.
        #expect(installed.active.browsePath.components == ["Shared", "Specs"])
        #expect(installed.active.relativePath == "")
        #expect(p.lines.contains(.init(level: .info, message: "Restored 3 left browse tabs")))
    }
}
