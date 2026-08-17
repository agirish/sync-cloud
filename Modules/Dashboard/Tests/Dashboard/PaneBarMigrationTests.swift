import Testing
import Foundation
import Events
@testable import Dashboard

/// Bringing a bar someone arranged on an earlier build forward when a new control ships.
///
/// The defect this closes was invisible to every other test in the repo, and the reason is worth
/// keeping: they all start from `PaneBarArrangement.default`, which carries every control by
/// construction. Only a *stored* arrangement — one written before the control existed — can be
/// missing it, and that is the state every real installation is in on the day of the release.
///
/// **`.serialized`, and it is load-bearing.** `PaneBarMigration.apply` writes to
/// `Logger.shared` now, and two of the tests below assert that a particular line is *absent*. This
/// suite is the only thing in the module that calls `apply`, so serializing it is what stops one
/// test's line landing inside another's absence window; nothing weaker would do, since the buffer
/// is shared process-wide.
@MainActor
@Suite(.serialized) struct PaneBarMigrationTests {

    /// Awaits a fresh log task, so everything enqueued before it is visible in `entries`.
    private func flushLog() async {
        await Logger.shared.debug("panebar-migration flush marker").value
    }

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

    /// **Delete does NOT migrate onto a stored bar**, and this is the assertion that says so.
    ///
    /// Search's migration exists because a discoverable affordance landed invisible in ⋯. The
    /// reasoning does not transfer to a destructive control: pushing Delete onto a bar someone
    /// arranged is what this mechanism makes possible, not what it exists to do. The bar below is
    /// one written before either control shipped, so it exercises the tempting mistake — running
    /// the migration and adding "whatever is new" — rather than a bar that happens to be current.
    @Test func testAStoredBarDoesNotGainDelete() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-no-delete")
        defaults.set("flexibleSpace,viewMode,backForward,scan,sort,hiddenFiles", forKey: PaneBar.arrangementKey)

        PaneBarMigration.apply(defaults: defaults)

        let migrated = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        #expect(!migrated.items.contains(.delete))
        // The Search step still ran, so this is "Delete was left out", not "the migration was
        // switched off" — the difference a test asserting only the absence could not see.
        #expect(migrated.items.contains(.search))
    }

    /// The stamp Search wrote is untouched: adding a control WITHOUT a migration step must not
    /// bump the version, or the next control to ship would find every bar already stamped past it
    /// and would silently never migrate.
    @Test func testTheSearchStampIsUnchanged() {
        #expect(PaneBarMigration.currentVersion == 1)
        // A bar stamped at Search's version is current, and stays untouched — which is only true
        // while `currentVersion` is still 1.
        let defaults = ScratchDefaults("PaneBarMigrationTests-stamp")
        defaults.set(1, forKey: PaneBar.migrationKey)
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        #expect(!PaneBarMigration.apply(defaults: defaults))
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "flexibleSpace,scan,sort")
    }

    /// The blind spot this whole suite exists for, pointed at the new case: a bar stored before
    /// `delete` existed must round-trip without gaining it — and without losing anything either,
    /// which is the half a `!contains(.delete)` assertion cannot see.
    @Test func testABarStoredBeforeDeleteRoundTripsUnchanged() {
        let stored = "flexibleSpace,viewMode,collapse,backForward,scan,newFolder,sort,hiddenFiles,preview,search"
        let arrangement = PaneBarArrangement(encoded: stored)
        #expect(!arrangement.items.contains(.delete))
        #expect(arrangement.encoded == stored)
    }

    // MARK: - Binding `PaneBarArrangement.default` to this mechanism
    //
    // Everything above tests the Search step and Delete's refusal — nine tests, and not one of them
    // starts from `PaneBarArrangement.default`. So the hazard this file's own source states in
    // prose ("a control added to `PaneBarArrangement.default` without a step below reaches a
    // customized bar through no route at all … and nothing anywhere will say so") was bound to
    // nothing at all, and the next control to ship could reproduce Search's bug in silence. Before
    // `9db37173` ⋯ was the consolation that made that survivable; a removal is permanent now, so
    // the omission has no symptom beyond a control the user simply never sees.

    /// Runs the migration against a bar arranged on an earlier build that is missing `control`, and
    /// answers whether the migration puts it back.
    ///
    /// The fixture is a *stored, pre-existing* arrangement — the whole point — and it is checked
    /// for actually omitting the control before the migration runs, since a fixture that already
    /// carried it would answer true for every control and this helper would be a rubber stamp.
    private func migrationPlaces(_ control: PaneBarItem) -> Bool {
        let defaults = ScratchDefaults("PaneBarMigrationTests-route-\(control.rawValue)")
        let stored = PaneBarArrangement(PaneBarArrangement.default.items.filter { $0 != control })
        #expect(!stored.items.contains(control),
                "the fixture for \(control.displayName) still carries it, so this answer means nothing")
        defaults.set(stored.encoded, forKey: PaneBar.arrangementKey)
        // Never stamped, i.e. a bar last written before the migration mechanism ran at all.
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == 0)

        PaneBarMigration.apply(defaults: defaults)

        let after = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        return after.items.contains(control)
    }

    /// **Every control on the shipped bar must be able to reach a bar someone customized**, and
    /// this names the one that cannot.
    ///
    /// Three routes, and a control has to be on exactly one of them: it shipped before this
    /// mechanism existed (so every stored bar already had the chance to carry it), a migration step
    /// places it (verified by running the migration, not by reading a list), or it declines a step
    /// deliberately. The declines are named here as well as in the source so a new control cannot
    /// join them with a one-line edit.
    @Test func testEveryControlOnTheDefaultBarHasARouteOntoACustomizedBar() {
        let deliberatelyDeclined: Set<PaneBarItem> = [.delete]
        #expect(PaneBarMigration.declinedControls == deliberatelyDeclined,
                "the set of controls that decline a migration step changed; that is a judgement call about a control's discoverability, not a bookkeeping edit — say why, in both places")
        // Frozen. These eight shipped before `PaneBarMigration` existed, so "a stored bar without
        // one" means someone removed it. A control that ships from here on cannot join them.
        #expect(PaneBarMigration.baselineControls == [.viewMode, .collapse, .backForward, .scan,
                                                      .newFolder, .sort, .hiddenFiles, .preview],
                "PaneBarMigration.baselineControls is a historical record and must not grow")
        // The loop below skips spacers; this is what keeps that skip honest, since a control
        // wrongly reporting `isSpacer` would otherwise be waved through.
        #expect(PaneBarArrangement.default.items.filter(\.isSpacer) == [.flexibleSpace],
                "the default bar's spacers changed — the exemption below covers layout, not controls")

        for control in PaneBarArrangement.default.items where !control.isSpacer {
            if PaneBarMigration.baselineControls.contains(control) { continue }
            if deliberatelyDeclined.contains(control) { continue }
            let complaint = """
                \(control.displayName) (case .\(control.rawValue)) ships on the default pane bar \
                and reaches a bar someone customized through NO ROUTE AT ALL: it predates nothing, \
                no migration step places it, and it is not a deliberate decline. Anyone who has \
                opened the customize sheet will never see it, and ⋯ no longer stands in. Add a \
                step to PaneBarMigration.apply and bump currentVersion, or name it in \
                declinedControls and in this test and say why.
                """
            #expect(migrationPlaces(control), "\(complaint)")
        }
    }

    /// The other direction: `migratedControls` is a *claim*, and this is what stops it drifting
    /// away from the steps in `apply`. A control named there that no step places would make the
    /// test above pass for a control with no route at all.
    @Test func testEveryControlTheMigrationClaimsToPlaceActuallyLands() {
        #expect(!PaneBarMigration.migratedControls.isEmpty,
                "no control is migrated at all — the accounting above would then be vacuous")
        for control in PaneBarMigration.migratedControls {
            #expect(migrationPlaces(control),
                    "PaneBarMigration.migratedControls names \(control.displayName), but running the migration on a stored bar without it does not put it back")
        }
        // A control cannot be on two routes at once: "we migrate it" and "we deliberately do not"
        // is a contradiction, and "it predates the mechanism" plus "a step adds it" is a step that
        // can never have anything to do.
        #expect(PaneBarMigration.migratedControls.isDisjoint(with: PaneBarMigration.declinedControls))
        #expect(PaneBarMigration.migratedControls.isDisjoint(with: PaneBarMigration.baselineControls))
        #expect(PaneBarMigration.baselineControls.isDisjoint(with: PaneBarMigration.declinedControls))
    }

    /// The same fact the accounting test proves, in the form the *runtime* warning reads — so the
    /// log line below cannot be armed against a different notion of "stranded" than the one the
    /// suite checks.
    @Test func testNoShippedControlIsStranded() {
        let stranded = PaneBarMigration.controlsWithoutARoute.map(\.displayName).joined(separator: ", ")
        #expect(PaneBarMigration.controlsWithoutARoute.isEmpty,
                "these ship on the default pane bar with no route onto a customized one: \(stranded)")
    }

    // MARK: - What a launch writes down about the bar

    /// **The already-stamped path is the one that has to say something**, and it is the path
    /// `apply` returns from on its second line without looking at the arrangement at all. Every
    /// launch after the one that migrated goes this way, so a bar missing a shipped control is
    /// silent forever if the report is put anywhere else.
    @Test func testAnAlreadyStampedLaunchStillSaysWhatTheBarCannotShow() async {
        let defaults = ScratchDefaults("PaneBarMigrationTests-reach-stamped")
        defaults.set(PaneBarMigration.currentVersion, forKey: PaneBar.migrationKey)
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)

        #expect(!PaneBarMigration.apply(defaults: defaults), "nothing to migrate on this path")
        await flushLog()

        // The literal, not a recomputation: a line assembled from the same call the source makes
        // would agree with itself whatever it said.
        #expect(Logger.shared.entries.contains {
            $0.message == "[panebar] The stored pane-bar arrangement omits View, Collapse Pane, "
                + "Back/Forward, New Folder, Hidden Files, Preview, Delete, Search"
                + " — put back from Customize Pane Bar…"
        }, "a launch on a bar missing eight shipped controls wrote nothing about it")
    }

    /// A bar carrying everything writes no line — the rule that keeps this proportional. An
    /// uncustomized install has no stored arrangement at all and is the common case; a line there
    /// would be one per launch for everybody, about nothing.
    @Test func testALaunchOnAnUntouchedBarWritesNothingAboutIt() async {
        let marker = "panebar-reach-silence-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let uncustomized = ScratchDefaults("PaneBarMigrationTests-reach-fresh")
        PaneBarMigration.apply(defaults: uncustomized)
        let full = ScratchDefaults("PaneBarMigrationTests-reach-full")
        full.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: full)
        await flushLog()

        let entries = Logger.shared.entries
        // Without this the absence below passes for free the moment the 1000-entry window rolls
        // past everything these two calls could have written.
        #expect(entries.contains { $0.message == marker },
                "the log window rolled past the marker — this absence proves nothing")
        let since = entries.drop(while: { $0.message != marker })
        #expect(!since.contains { $0.message.hasPrefix("[panebar] The stored pane-bar arrangement") },
                "a bar that carries every shipped control was reported as missing something")
    }

    /// The stranded-control warning, driven by an injected list because in a correct build there is
    /// nothing stranded — the branch that matters is the one no honest fixture can reach.
    @Test func testTheStrandedControlWarningNamesTheControlAndOnlyWhenItIsMissing() {
        let bar = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        #expect(PaneBarMigration.unreachableMessage(for: bar, withoutARoute: [.delete])
                == "[panebar] Delete ship(s) on the default pane bar with no migration step,"
                + " so this stored arrangement can never show it — see PaneBarMigration")
        // Nothing stranded, nothing said — the state of a correct build.
        #expect(PaneBarMigration.unreachableMessage(for: bar, withoutARoute: []) == nil)
        // Stranded in the code but present on this bar: this user can see it, so there is nothing
        // to tell them. Without this the warning would fire for every install on a bad build,
        // including the ones the defect cannot reach.
        let carriesIt = PaneBarArrangement(encoded: "flexibleSpace,scan,delete")
        #expect(PaneBarMigration.unreachableMessage(for: carriesIt, withoutARoute: [.delete]) == nil)
    }
}
