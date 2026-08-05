import Testing
import Foundation
@testable import Dashboard

/// Bringing a bar someone arranged on an earlier build forward when a new control ships.
///
/// The defect this closes was invisible to every other test in the repo, and the reason is worth
/// keeping: they all start from `PaneBarArrangement.default`, which carries every control by
/// construction. Only a *stored* arrangement — one written before the control existed — can be
/// missing it, and that is the state every real installation is in on the day of the release.
@Suite struct PaneBarMigrationTests {

    /// A stored bar that predates Search must gain it, at the trailing end, rather than keeping it
    /// in ⋯ forever. This is the reported bug: the magnifier sat in the overflow menu on a bar with
    /// visible empty space.
    @Test func testAStoredBarGainsSearch() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-gains")
        defaults.set("flexibleSpace,viewMode,backForward,scan,sort,hiddenFiles", forKey: PaneBar.arrangementKey)

        #expect(PaneBarMigration.apply(defaults: defaults))

        let migrated = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        #expect(migrated.items.contains(.search))
        #expect(migrated.items.last == .search)
        // …and nothing else moved: a migration that reshuffles a bar someone arranged is worse than
        // the problem it fixes.
        #expect(migrated.items.dropLast() == [.flexibleSpace, .viewMode, .backForward, .scan, .sort, .hiddenFiles])
    }

    /// The half that makes stamping the right mechanism rather than a re-check: once migrated, a
    /// deliberate removal has to stick. A bar item that grows back is worse than one that never
    /// appeared, because the user can see they are being overruled.
    @Test func testRemovingSearchAfterwardsSticks() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-sticks")
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: defaults)
        #expect(PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey)!).items.contains(.search))

        // The user drags it off.
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        #expect(!PaneBarMigration.apply(defaults: defaults), "already stamped — nothing to do")
        #expect(!PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey)!).items.contains(.search))
    }

    /// Running twice must change nothing the second time — `App.init` can be re-run by SwiftUI.
    @Test func testTheMigrationIsIdempotent() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-idempotent")
        defaults.set("flexibleSpace,scan", forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: defaults)
        let once = defaults.string(forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: defaults)
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == once)
    }

    /// A bar that was never customized has no stored arrangement and reads the default, which
    /// already carries Search. It is stamped anyway — otherwise the FIRST time such a user
    /// customized their bar, the next launch would migrate the result and undo whatever they had
    /// just done with Search.
    @Test func testAnUncustomizedBarIsStampedWithoutBeingWritten() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-fresh")
        // FALSE, for the same reason `testAFullBarIsLeftAloneAndSaysSo` expects false: the return
        // value is "was a stored arrangement rewritten", and there is no stored arrangement. This
        // expected `true` and so held the return value to the opposite contract from its sibling —
        // which is how the app came to log a migration on every uncustomized install.
        #expect(!PaneBarMigration.apply(defaults: defaults))
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == nil, "nothing to migrate, nothing written")
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == PaneBarMigration.currentVersion)
    }

    /// **A bar that is already full cannot take Search, and the migration must say so.**
    /// `PaneBarArrangement.insert` refuses at `maxItems` and refuses SILENTLY, and spacers are
    /// repeatable, so a 16-item bar is something a user can actually build. The first version set a
    /// `changed` flag beside the `insert` call and so reported a migration that had not happened,
    /// rewriting the arrangement with identical contents. The result is compared now, not assumed.
    @Test func testAFullBarIsLeftAloneAndSaysSo() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-full")
        // Sixteen items, none of them Search — spacers make the length reachable.
        let full = PaneBarArrangement([.scan, .backForward, .sort, .hiddenFiles, .viewMode, .newFolder,
                                       .preview, .collapse, .flexibleSpace] + Array(repeating: .space, count: 7))
        #expect(full.items.count == PaneBarArrangement.maxItems, "the fixture must actually be full")
        #expect(!full.items.contains(.search))
        defaults.set(full.encoded, forKey: PaneBar.arrangementKey)

        #expect(!PaneBarMigration.apply(defaults: defaults),
                "nothing was rewritten, so the migration must not claim it was")
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == full.encoded, "the bar must be untouched")
        // …and it is still STAMPED, so it does not retry every launch for a bar it cannot help.
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == PaneBarMigration.currentVersion)
    }

    /// An already-current install is left entirely alone.
    @Test func testACurrentInstallIsNotTouched() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-current")
        defaults.set(PaneBarMigration.currentVersion, forKey: PaneBar.migrationKey)
        defaults.set("flexibleSpace,scan", forKey: PaneBar.arrangementKey)
        #expect(!PaneBarMigration.apply(defaults: defaults))
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "flexibleSpace,scan")
    }
}
