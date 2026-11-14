import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Dashboard

/// Bringing a bar arranged on an earlier build forward when a new control ships. Tests that start
/// from `PaneBarArrangement.default` can't see this, since the default carries every control; only
/// a stored arrangement written before the control existed lacks it, which is every real install on
/// release day.
///
/// `.serialized` orders only this suite, while the `Logger.shared` buffer is process-wide and every
/// suite writes into it at once. What keeps the log assertions safe:
///
/// * A capture, not the buffer. Every read, presence or absence, comes from a `LogCapture` opened
///   before the call, since the buffer is capped at 1000 entries and siblings can roll past this
///   test's lines ("A log assertion reading a window that has already rolled" in
///   `docs/flaky-tests.md`). Each absence also finds a line of the test's own, so a capture that
///   heard nothing can't pass it.
/// * Disjoint predicates. The absences look for `[panebar] The stored pane-bar arrangement`, which
///   nothing outside this file writes.
/// * `.serialized` on top, which keeps the captures short.
@MainActor
@Suite(.serialized) struct PaneBarMigrationTests {

    /// A never-customized bar has no stored arrangement and reads the default, which already
    /// carries every control. It is stamped anyway, or the launch after the user's first
    /// customization would migrate it and undo what they did with Filter by Type.
    @Test func testAnUncustomizedBarIsStampedWithoutBeingWritten() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-fresh")
        // `.unchanged`, as in `testAFullBarIsLeftAloneAndSaysSo`: the result is what this run put
        // onto a stored arrangement, and there is none. Anything else would log a migration on
        // every uncustomized install.
        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged)
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == nil, "nothing to migrate, nothing written")
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == PaneBarMigration.currentVersion)
    }

    /// A full bar can't take a migrated control, and the migration must say so.
    /// `PaneBarArrangement.insert` refuses silently at `maxItems`, and spacers repeat, so a user can
    /// build a full bar. The migration must compare the result, not assume its insert landed. Runs
    /// over `migratedControls`, so the next step joins by construction; nothing else here reaches
    /// the cap.
    @Test func testAFullBarIsLeftAloneAndSaysSo() {
        #expect(!PaneBarMigration.migratedControls.isEmpty, "no step to refuse — this would be vacuous")
        for control in PaneBarMigration.migratedControls {
            let defaults = ScratchDefaults("PaneBarMigrationTests-full-\(control.rawValue)")
            // `maxItems` items, none of them `control`; spacers make the length reachable.
            let base = PaneBarArrangement.default.items.filter { $0 != control }
            let full = PaneBarArrangement(
                base + Array(repeating: .space, count: PaneBarArrangement.maxItems - base.count))
            #expect(full.items.count == PaneBarArrangement.maxItems, "the fixture must actually be full")
            #expect(!full.items.contains(control),
                    "the fixture for \(control.displayName) still carries it, so the refusal is not what is being measured")
            defaults.set(full.encoded, forKey: PaneBar.arrangementKey)

            #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged,
                    "nothing was rewritten, so the migration must not claim it was")
            #expect(defaults.string(forKey: PaneBar.arrangementKey) == full.encoded,
                    "the bar must be untouched")
            // …and it is still stamped, so it doesn't retry every launch for a bar it can't help.
            #expect(defaults.integer(forKey: PaneBar.migrationKey) == PaneBarMigration.currentVersion)
        }
    }

    /// An already-current install is left entirely alone.
    @Test func testACurrentInstallIsNotTouched() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-current")
        defaults.set(PaneBarMigration.currentVersion, forKey: PaneBar.migrationKey)
        defaults.set("flexibleSpace,scan", forKey: PaneBar.arrangementKey)
        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged)
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "flexibleSpace,scan")
    }

    /// Delete doesn't migrate onto a stored bar. Migration is for discoverable affordances; pushing
    /// a destructive control onto a bar someone arranged is not its job. The bar predates both
    /// controls, so it tests the tempting mistake of adding whatever is new.
    @Test func testAStoredBarDoesNotGainDelete() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-no-delete")
        defaults.set("flexibleSpace,viewMode,backForward,scan,sort,hiddenFiles", forKey: PaneBar.arrangementKey)

        PaneBarMigration.apply(defaults: defaults)

        let migrated = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        #expect(!migrated.items.contains(.delete))
        // The Filter by Type step still ran, so this is "Delete was left out", not "the migration
        // was off".
        #expect(migrated.items.contains(.typeFilter))
    }

    /// Filter by Type's step (version 2): a bar migrated for Search gains it just before Search,
    /// once, and nothing else moves but Info's step (version 3), which lands right after Scan.
    @Test func testABarStampedForSearchGainsTheFilterBeforeIt() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-filter")
        defaults.set(1, forKey: PaneBar.migrationKey)
        defaults.set("backForward,scan,search,newFolder", forKey: PaneBar.arrangementKey)
        #expect(PaneBarMigration.apply(defaults: defaults) == .rewritten(added: [.info, .typeFilter], removed: []))
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "backForward,scan,info,typeFilter,search,newFolder")
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == 3)
    }

    /// Info's step (version 3): a bar already migrated for Filter by Type gains Info right after
    /// Scan, once, and nothing else moves.
    @Test func testABarStampedForTheFilterGainsInfoAfterScan() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-info")
        defaults.set(2, forKey: PaneBar.migrationKey)
        defaults.set("backForward,scan,newFolder,typeFilter,search", forKey: PaneBar.arrangementKey)
        #expect(PaneBarMigration.apply(defaults: defaults) == .rewritten(added: [.info], removed: []))
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "backForward,scan,info,newFolder,typeFilter,search")
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == 3)
        // Once: a second launch writes nothing, and a deliberate removal afterwards sticks.
        defaults.set("backForward,scan,newFolder,typeFilter,search", forKey: PaneBar.arrangementKey)
        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged)
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "backForward,scan,newFolder,typeFilter,search")
    }

    /// The retired `preview` token is not Info: a bar that carries it gains Info like any other,
    /// and the token rides through untouched.
    @Test func testAStoredRetiredPreviewIsNotInfo() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-info-preview")
        defaults.set(2, forKey: PaneBar.migrationKey)
        defaults.set("backForward,scan,preview,search", forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: defaults)
        let stored = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        #expect(stored.items.contains(.info), "the retired preview token kept Info off the bar")
        #expect(stored.encoded.contains("preview"), "the retired token was dropped from the stored bar")
    }

    /// A bar that dropped Search gets the filter at its trailing end rather than not at all.
    @Test func testABarWithoutSearchGainsTheFilterAtTheEnd() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-filter-nosearch")
        defaults.set(1, forKey: PaneBar.migrationKey)
        defaults.set("backForward,scan,sort", forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: defaults)
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "backForward,scan,info,sort,typeFilter")
    }

    /// A bar stored before `delete` existed round-trips without gaining it, and without losing
    /// anything, which a `!contains(.delete)` check alone can't see.
    @Test func testABarStoredBeforeDeleteRoundTripsUnchanged() {
        let stored = "flexibleSpace,viewMode,collapse,backForward,scan,newFolder,sort,hiddenFiles,search"
        let arrangement = PaneBarArrangement(encoded: stored)
        #expect(!arrangement.items.contains(.delete))
        #expect(arrangement.encoded == stored)
    }

    /// A default bar that only carries a token counts as the default, so Restore isn't offered, and
    /// Restore keeps the token. Otherwise Restore would change nothing on screen, log a reorder,
    /// and drop `preview` for good.
    @Test func aDefaultBarCarryingARetiredTokenIsTheDefault() throws {
        let carried = PaneBarArrangement(encoded: PaneBarArrangement.default.encoded + ",preview")
        #expect(carried != .default, "the token is not carried — nothing below measures anything")
        #expect(carried.drawsTheDefault)
        #expect(carried.restoredToDefault.encoded == carried.encoded)
        #expect(PaneBarEditLog.message(from: carried, to: carried.restoredToDefault) == nil)

        var moved = carried
        let first = moved.items.firstIndex { $0.isRemovable }
        let removable = try #require(first)
        moved.remove(at: removable)
        #expect(!moved.drawsTheDefault)
        #expect(moved.restoredToDefault.encoded == carried.encoded,
                "Restore dropped the carried token")
    }

    /// Changing the shipped default doesn't rewrite a bar someone is using. The default has no
    /// leading `flexibleSpace`, but older stored bars do, and that stored list is the user's answer
    /// to where their controls go. So the space survives the migration, and a control it adds lands
    /// after the space, at the trailing edge with the rest of the bar, not packed left before it.
    @Test func theMigrationKeepsAStoredFlexibleSpaceAndPlacesAroundIt() throws {
        let defaults = ScratchDefaults("PaneBarMigrationTests-storedSpace")
        // A bar as older builds wrote it: a leading space, and no Filter by Type for the migration
        // to place.
        let stored = PaneBarArrangement([.flexibleSpace] + PaneBarArrangement.default.items.filter { $0 != .typeFilter })
        #expect(stored.items.first == .flexibleSpace, "the fixture is not the shape this test is about")
        defaults.set(stored.encoded, forKey: PaneBar.arrangementKey)

        PaneBarMigration.apply(defaults: defaults)

        let after = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        #expect(after.items.first == .flexibleSpace,
                "the migration took the user's leading flexible space off their bar: \(after.encoded)")
        let space = try #require(after.items.firstIndex(of: .flexibleSpace))
        let filter = try #require(after.items.firstIndex(of: .typeFilter),
                                  "the migration did not place Filter by Type at all, so this test compares nothing")
        #expect(filter > space,
                "Filter by Type landed before the user's flexible space, packed against the breadcrumb rather than at the pane's trailing edge with the rest of their bar: \(after.encoded)")
    }

    // MARK: - Binding `PaneBarArrangement.default` to this mechanism
    //
    // A control added to `PaneBarArrangement.default` without a migration step never reaches a
    // customized bar, not even in ⋯, and the user just never sees it. These bind every default
    // control to a route.

    /// Runs the migration on a stored bar missing `control` and answers whether it puts the control
    /// back where the shipped default puts it. The fixture is checked for omitting the control
    /// first, or this would answer true for everything.
    ///
    /// Position matters, not just `contains`: for every other item on the bar, the migrated control
    /// must fall on the same side of it as in `PaneBarArrangement.default`. Not checked: surviving
    /// the first layout rung, since an appended control is shed first and for Search that is the
    /// design. A step gated above `currentVersion` is caught by
    /// `testNoMigrationStepIsGatedAboveTheCurrentVersion`, not here.
    private func migrationPlaces(_ control: PaneBarItem) throws -> Bool {
        let defaults = ScratchDefaults("PaneBarMigrationTests-route-\(control.rawValue)")
        let stored = PaneBarArrangement(PaneBarArrangement.default.items.filter { $0 != control })
        #expect(!stored.items.contains(control),
                "the fixture for \(control.displayName) still carries it, so this answer means nothing")
        defaults.set(stored.encoded, forKey: PaneBar.arrangementKey)
        // Never stamped: a bar last written before the migration ever ran.
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == 0)

        PaneBarMigration.apply(defaults: defaults)

        let after = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        guard let landed = after.items.firstIndex(of: control) else { return false }

        // Nothing else moved, which `contains` can't see.
        #expect(after.items.filter { $0 != control } == stored.items,
                "migrating \(control.displayName) disturbed the rest of the bar: \(after.encoded)")

        // …and it landed in the shipped default's relative order. `#require` for the index read:
        // `#expect` records and continues, and a comparison on a missing index would crash the host.
        let defaultItems = PaneBarArrangement.default.items
        let defaultIndex = try #require(defaultItems.firstIndex(of: control),
                                        "\(control.displayName) is not on the default bar at all")
        var compared = 0
        for other in after.items where other != control {
            guard let otherAfter = after.items.firstIndex(of: other),
                  let otherDefault = defaultItems.firstIndex(of: other) else { continue }
            compared += 1
            let wrongSide = "the migration put \(control.displayName) on the wrong side of "
                + "\(other.displayName) — the shipped bar is \(PaneBarArrangement.default.encoded), "
                + "this one is \(after.encoded)"
            #expect((landed < otherAfter) == (defaultIndex < otherDefault), "\(wrongSide)")
        }
        // The loop `continue`s, so this says it ran: every other item was compared, none skipped.
        // A stored leading flexible space is covered by
        // `theMigrationKeepsAStoredFlexibleSpaceAndPlacesAroundIt`, since the default has none.
        #expect(compared == after.items.count - 1,
                "the ordering check skipped \(after.items.count - 1 - compared) of the bar's items")
        return true
    }

    /// Every control on the shipped bar can reach a customized bar, and this names one that can't.
    /// Each control is on exactly one route: it predates the mechanism, a migration step places it
    /// (checked by running the migration), or it declines a step on purpose. The declines are named
    /// here as well as in the source, so a new control can't join them with a one-line edit.
    @Test func testEveryControlOnTheDefaultBarHasARouteOntoACustomizedBar() throws {
        let deliberatelyDeclined: Set<PaneBarItem> = [.delete]
        #expect(PaneBarMigration.declinedControls == deliberatelyDeclined,
                "the set of controls that decline a migration step changed; that is a judgement call about a control's discoverability, not a bookkeeping edit — say why, in both places")
        // Frozen: these are on every bar a 6.x build could have stored, so a stored bar without one
        // means someone removed it. A control shipped later can't join them.
        #expect(PaneBarMigration.baselineControls == [.viewMode, .collapse, .backForward, .scan,
                                                      .newFolder, .sort, .hiddenFiles, .search],
                "PaneBarMigration.baselineControls is a historical record and must not grow")
        // The loop below skips spacers, so a control wrongly reporting `isSpacer` would be waved
        // through. The shipped bar carries none, so nothing on it may claim to be one.
        #expect(PaneBarArrangement.default.items.filter(\.isSpacer) == [],
                "the default bar's spacers changed — the exemption below covers layout, not controls")

        // The accounting, both ways. A shipped control on no route is the hazard itself. A routed
        // control that doesn't ship is the direction the loop is blind to: `migrationPlaces` would
        // remove a control the default lacks, pass its guard vacuously and answer true.
        let shipped = Set(PaneBarArrangement.default.items.filter { !$0.isSpacer })
        let unrouted = shipped.subtracting(PaneBarMigration.routedControls).map(\.displayName).sorted()
        let unshipped = PaneBarMigration.routedControls.subtracting(shipped).map(\.displayName).sorted()
        let disagreement = "the routes and the shipped bar disagree — on the bar with no route: "
            + "\(unrouted); on a route but not on the bar: \(unshipped)"
        #expect(PaneBarMigration.routedControls == shipped, "\(disagreement)")
        // The same fact in the form the runtime warning reads, so the log line can't use a
        // different notion of "stranded".
        let stranded = PaneBarMigration.controlsWithoutARoute.map(\.displayName).joined(separator: ", ")
        #expect(PaneBarMigration.controlsWithoutARoute.isEmpty,
                "these ship on the default pane bar with no route onto a customized one: \(stranded)")

        var checked: Set<PaneBarItem> = []
        for control in PaneBarArrangement.default.items where !control.isSpacer {
            if PaneBarMigration.baselineControls.contains(control) { continue }
            if deliberatelyDeclined.contains(control) { continue }
            checked.insert(control)
            let complaint = """
                \(control.displayName) (case .\(control.rawValue)) ships on the default pane bar \
                and reaches a bar someone customized through NO ROUTE AT ALL: it predates nothing, \
                no migration step places it, and it is not a deliberate decline. Anyone who has \
                opened the customize sheet will never see it, and ⋯ no longer stands in. Add a \
                step to PaneBarMigration.apply and bump currentVersion, or name it in \
                declinedControls and in this test and say why.
                """
            #expect(try migrationPlaces(control), "\(complaint)")
        }

        // The loop `continue`s twice, so this says the body ran, naming a member so "every control
        // got skipped" can't read as "every control has a route".
        let neverRan = "the route loop never reached Filter by Type — every shipped control was "
            + "skipped as baseline or declined, so this test proved nothing about any of them"
        #expect(checked.contains(.typeFilter), "\(neverRan)")
    }

    /// `migratedControls` is a claim, and this keeps it in step with `apply`: a control named there
    /// that no step places would pass the test above with no route at all.
    @Test func testEveryControlTheMigrationClaimsToPlaceActuallyLands() throws {
        #expect(!PaneBarMigration.migratedControls.isEmpty,
                "no control is migrated at all — the accounting above would then be vacuous")
        for control in PaneBarMigration.migratedControls {
            #expect(try migrationPlaces(control),
                    "PaneBarMigration.migratedControls names \(control.displayName), but running the migration on a stored bar without it does not put it back")
        }
        // A control can't be on two routes: migrated and declined contradict, and a baseline
        // control's step would never have anything to do.
        #expect(PaneBarMigration.migratedControls.isDisjoint(with: PaneBarMigration.declinedControls))
        #expect(PaneBarMigration.migratedControls.isDisjoint(with: PaneBarMigration.baselineControls))
        #expect(PaneBarMigration.baselineControls.isDisjoint(with: PaneBarMigration.declinedControls))
    }

    /// A step gated above `currentVersion` never runs for installs already stamped, the very ones a
    /// new step is for, and every behavioural test here is blind to it: their fixtures start
    /// unstamped, where any gate passes. That is "add a step, forget to bump `currentVersion`".
    /// The same equality catches the reverse, a bump without a step.
    ///
    /// A source scan of the literals: the highest step gate must equal `currentVersion`. Comment
    /// lines are stripped first, since prose quotes the gates.
    @Test func testNoMigrationStepIsGatedAboveTheCurrentVersion() throws {
        let source = try DashboardSource.read("PaneBarArrangement.swift", codeOnly: true)
        var gates: [Int] = []
        var rest = Substring(source)
        while let hit = rest.range(of: "if from < ") {
            let digits = rest[hit.upperBound...].prefix(while: \.isNumber)
            if let gate = Int(digits) { gates.append(gate) }
            rest = rest[hit.upperBound...]
        }
        // The anchor: Filter by Type's step is gated at 2; a scan that can't find it is reading the
        // wrong text and would pass for free.
        let noAnchor = "no migration step gated `if from < 2` was found in PaneBarArrangement.swift "
            + "— either Filter by Type's step is gone or this scan no longer matches how a step is "
            + "written, and the check below is vacuous either way. Found: \(gates)"
        #expect(gates.contains(2), "\(noAnchor)")
        let highest = gates.max().map(String.init) ?? "nothing"
        let outOfStep = "the newest migration step is gated at \(highest) but currentVersion is "
            + "\(PaneBarMigration.currentVersion). A step gated ABOVE the current version never runs "
            + "for a stamped install — every bar already migrated once, which is everyone the new "
            + "step is for — and one gated BELOW it is a step nothing can reach. Bump currentVersion "
            + "in the same edit as the step."
        #expect(gates.max() == PaneBarMigration.currentVersion, "\(outOfStep)")
    }

    /// The derivation behind the runtime warning, proven to derive something. In a correct build
    /// `controlsWithoutARoute` is empty, so a version hard-wired to `[]` would pass every check of
    /// it. Handed inputs, it must name the whole shipped bar with no routes, and exactly one
    /// route's members with that route removed.
    @Test func testTheRouteDerivationNamesWhatTheRoutesDoNotCover() {
        // Written out, not recomputed from `default.items`: that is the derivation under test.
        let shipped: [PaneBarItem] = [.viewMode, .collapse, .backForward, .scan, .info, .newFolder, .sort,
                                      .hiddenFiles, .delete, .typeFilter, .search]
        #expect(PaneBarArrangement.default.encoded == "viewMode,collapse,backForward,"
                + "scan,info,newFolder,sort,hiddenFiles,delete,typeFilter,search",
                "the shipped bar changed; the literal below is what this test is measuring against")
        let withNoRoutes = PaneBarMigration.controlsWithoutARoute(shipping: .default, routed: [])
        let namedInstead = "with no routes declared, every shipped control is stranded — this named "
            + "\(withNoRoutes.map(\.displayName))"
        #expect(withNoRoutes == shipped, "\(namedInstead)")
        // Spacers are layout, not ability, and are exempt even when nothing routes them. Tested on
        // a bar built to carry one, so the exemption stays tested whatever the default holds.
        let withSpacer = PaneBarArrangement([.flexibleSpace] + PaneBarArrangement.default.items)
        #expect(withSpacer.items.contains(.flexibleSpace), "the fixture lost its spacer on the way in")
        #expect(PaneBarMigration.controlsWithoutARoute(shipping: withSpacer, routed: []) == shipped,
                "the spacer was named as a stranded control — spacers are layout, not ability")
        // And dropping one route strands exactly its members.
        #expect(PaneBarMigration.controlsWithoutARoute(
                    shipping: .default,
                    routed: PaneBarMigration.routedControls.subtracting([.search])) == [.search])
    }

    /// The two wirings behind the stranded warning that only source can show. `unreachableMessage`
    /// takes an injected list, so a caller could pass `[]` and kill the warning with every test
    /// green; and `controlsWithoutARoute` could stop consulting the routes. Neither shows in
    /// behaviour while the honest answer is empty. The declaration is required first, so a rename
    /// fails loudly.
    @Test func testTheStrandedWarningIsWiredToTheRealRouteList() throws {
        let source = try DashboardSource.read("PaneBarArrangement.swift", codeOnly: true)
        _ = try #require(source.range(of: "public static func reportStoredArrangementReach"),
                         "the report function is gone or renamed; both checks below are vacuous")
        let notTheRealList = "reportStoredArrangementReach no longer defaults its stranded list to "
            + "the real one; a caller that omits the argument now gets something else"
        #expect(source.contains("withoutARoute: [PaneBarItem] = controlsWithoutARoute"),
                "\(notTheRealList)")
        let notDerived = "controlsWithoutARoute no longer derives itself from the three routes, so "
            + "the accounting the route test checks and the list the warning reads have come apart"
        #expect(source.contains("controlsWithoutARoute(shipping: .default, routed: routedControls)"),
                "\(notDerived)")
    }

    /// The launch line names what this run added, and a new step joins by construction. `apply` is
    /// run, not read off `migratedControls`, so a step claiming a control it doesn't place fails
    /// here, and `migrationMessage` gets exactly what `apply` answered. Every control in
    /// `migratedControls` must appear in the line, so nobody has to remember the call site.
    @Test func theLaunchLineNamesEveryControlTheMigrationActuallyAdded() {
        #expect(!PaneBarMigration.migratedControls.isEmpty,
                "no control is migrated at all — the loop below would be vacuous")
        for control in PaneBarMigration.migratedControls {
            let defaults = ScratchDefaults("PaneBarMigrationTests-line-\(control.rawValue)")
            let stored = PaneBarArrangement(PaneBarArrangement.default.items.filter { $0 != control })
            #expect(!stored.items.contains(control),
                    "the fixture for \(control.displayName) still carries it, so this answer means nothing")
            defaults.set(stored.encoded, forKey: PaneBar.arrangementKey)
            #expect(defaults.integer(forKey: PaneBar.migrationKey) == 0, "the fixture is already stamped")

            let outcome = PaneBarMigration.apply(defaults: defaults)
            #expect(outcome == .rewritten(added: [control], removed: []),
                    "the migration put \(control.displayName) onto the bar but reported \(outcome) — the launch line says whatever this returns")
            let line = PaneBarMigration.migrationMessage(for: outcome)
            #expect(line?.contains(control.displayName) == true,
                    "the launch line does not name \(control.displayName), which this run added: \(line ?? "nil")")
        }

        // Two at once, as a literal: a bar arranged before both controls shipped gains both on one
        // launch. Written out, not recomputed, which would agree with itself.
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [.search, .delete], removed: []))
                == "[panebar] rewrote a stored pane-bar arrangement: added Search, Delete",
                "the line cannot name more than one control, which is the whole reason it stopped being a literal")
        // Nothing happened, nothing said: the only outcome that may go unlogged. A `.rewritten`
        // with nothing nameable is covered by
        // `everyRewriteLogsSomethingEvenWhenItCannotNameWhatChanged`.
        #expect(PaneBarMigration.migrationMessage(for: .unchanged) == nil,
                "a launch that migrated nothing still writes a line claiming it did")
    }

    /// Every rewrite logs something, even one it can't name. A removal, a reorder or a repeatable
    /// insertion adds no nameable control, yet writes the bar back, and `~/sync-cloud.log` must
    /// still say the bar was rewritten under its owner.
    ///
    /// Fixtures are built by hand, not from `PaneBarArrangement.default`: the subject is the shape
    /// of a change, so no control list is enumerated. Fed to `PaneBarMigration.outcome` directly,
    /// because the shipped steps are pure additions and `apply` can't produce these shapes; `apply`
    /// routes its write through `outcome` (`theMigrationRoutesItsOwnAnswerThroughOutcome`), so this
    /// covers every future step.
    @Test func everyRewriteLogsSomethingEvenWhenItCannotNameWhatChanged() {
        // The three shapes, each as its own before/after so a reader can check the premise.
        let shapes: [(String, [PaneBarItem], [PaneBarItem])] = [
            ("removal", [.scan, .sort, .hiddenFiles], [.scan, .hiddenFiles]),
            ("reorder", [.scan, .sort, .hiddenFiles], [.hiddenFiles, .sort, .scan]),
            ("repeatable insertion", [.scan, .space, .sort], [.scan, .space, .sort, .space]),
        ]
        for (shape, before, after) in shapes {
            #expect(before != after, "the \(shape) fixture does not change the bar — it proves nothing")
            let outcome = PaneBarMigration.outcome(before: before, after: after)
            #expect(outcome != .unchanged,
                    "a \(shape) rewrites the stored bar and `outcome` called it unchanged")
            // Not "names what it did" (a reorder has no name) but "says the bar was rewritten",
            // which must never depend on the migration describing its own work.
            let line = PaneBarMigration.migrationMessage(for: outcome)
            #expect(line != nil, "a \(shape) rewrote the bar and the launch log said nothing")
            #expect(line?.contains("rewrote a stored pane-bar arrangement") == true,
                    "the \(shape) line does not say the bar was rewritten: \(line ?? "nil")")
        }

        // The nameable shapes say what they can on the same stem, so one grep finds every rewrite.
        #expect(PaneBarMigration.outcome(before: [.scan, .sort], after: [.scan, .sort, .search])
                == .rewritten(added: [.search], removed: []))
        #expect(PaneBarMigration.outcome(before: [.scan, .sort], after: [.scan])
                == .rewritten(added: [], removed: [.sort]))
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [], removed: [.sort]))
                == "[panebar] rewrote a stored pane-bar arrangement: removed Sort")
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [.search], removed: [.sort]))
                == "[panebar] rewrote a stored pane-bar arrangement: added Search, removed Sort")
        // The unnameable rewrite's whole sentence, as a literal.
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [], removed: []))
                == "[panebar] rewrote a stored pane-bar arrangement")

        // A repeatable item added twice is still named once: "added Space, Space" is not a sentence.
        #expect(PaneBarMigration.outcome(before: [.scan], after: [.scan, .space, .space])
                == .rewritten(added: [.space], removed: []))
    }

    /// The call-site half of the test above: `apply`'s answer must equal what `outcome` says about
    /// the same before/after, or `outcome` could be a well-tested function nothing calls. An
    /// `apply` that kept its own derivation beside the write must fail here.
    @Test func theMigrationRoutesItsOwnAnswerThroughOutcome() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-routes-through-outcome")
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,sort,hiddenFiles").items
        #expect(!before.contains(.typeFilter), "the fixture already carries Filter by Type — nothing would migrate")
        defaults.set(PaneBarArrangement(before).encoded, forKey: PaneBar.arrangementKey)

        let applied = PaneBarMigration.apply(defaults: defaults)
        let after = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "").items
        #expect(after != before, "the fixture did not migrate, so this comparison is vacuous")
        // Recomputed from the two bars actually stored, not from `applied`.
        #expect(applied == PaneBarMigration.outcome(before: before, after: after),
                "`apply` reported \(applied) but `outcome` reads the same rewrite as \(PaneBarMigration.outcome(before: before, after: after))")
        #expect(PaneBarMigration.migrationMessage(for: applied) != nil,
                "the one rewrite `apply` can produce logs nothing")
    }

    // MARK: - What a launch writes down about the bar

    /// An already-stamped install still gets its report. `apply` returns early for it without
    /// reading the arrangement, and every launch after the migrating one is that install, so the
    /// report must run whether or not anything migrated.
    @Test func testAnAlreadyStampedLaunchStillSaysWhatTheBarCannotShow() async {
        let log = LogCapture()

        let defaults = ScratchDefaults("PaneBarMigrationTests-reach-stamped")
        defaults.set(PaneBarMigration.currentVersion, forKey: PaneBar.migrationKey)
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)

        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged, "nothing to migrate on this path")
        PaneBarMigration.reportStoredArrangementReach(defaults: defaults)

        // The literal, not a recomputation, which would agree with itself. Delete isn't in it (see
        // `omissionMessage`): a declined control is absent by design, not by the user's doing.
        #expect(await log.entries.contains {
            $0.message == "[panebar] The stored pane-bar arrangement omits View, Collapse Pane, "
                + "Back/Forward, Info, New Folder, Hidden Files, Filter by Type, Search"
                + " — put back from Customize Pane Bar…"
        }, "a launch on a bar missing eight shipped controls wrote nothing about it")
    }

    /// `apply` writes no report of its own. Its caller is `App.init`, which SwiftUI may re-run, so a
    /// report there would repeat on every rebuild of the scene. The report belongs to the delegate:
    /// `applicationDidFinishLaunching` fires once per process. A
    /// `defer { reportStoredArrangementReach(…) }` in `apply` must fail here.
    @Test func testTheMigrationItselfWritesNoReachReport() async {
        let log = LogCapture()

        // A bar missing almost everything, so any report from `apply` would show.
        let stamped = ScratchDefaults("PaneBarMigrationTests-reach-apply-stamped")
        stamped.set(PaneBarMigration.currentVersion, forKey: PaneBar.migrationKey)
        stamped.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: stamped)
        // …and the migrating path too, since a `defer` fires on every way out.
        let migrating = ScratchDefaults("PaneBarMigrationTests-reach-apply-migrating")
        migrating.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        #expect(PaneBarMigration.apply(defaults: migrating) == .rewritten(added: [.info, .typeFilter], removed: []),
                "the fixture must really migrate")
        // After both calls, so a capture that holds it was listening across them.
        let marker = "panebar-reach-not-from-apply-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let entries = await log.entries
        #expect(entries.contains { $0.message == marker },
                "the capture never saw this test's own line — this absence proves nothing")
        let reportedFromApply = "PaneBarMigration.apply wrote the reach report; App.init can be "
            + "re-run, so it would repeat for the same launch — the delegate owns this line"
        #expect(!entries.contains { $0.message.hasPrefix("[panebar] The stored pane-bar arrangement") },
                "\(reportedFromApply)")
        // Positive control: the same fixture, reported deliberately, does write, so the absence
        // above isn't just a missing report.
        PaneBarMigration.reportStoredArrangementReach(defaults: stamped)
        #expect(await log.entries.contains {
            $0.message.hasPrefix("[panebar] The stored pane-bar arrangement omits")
        }, "nothing reports this bar at all, so the absence above says nothing about where the report lives")
    }

    /// The stranded warning reaches the log, not just the pure `unreachableMessage`. Deleting the
    /// `Logger.shared.warning` call in `reportStoredArrangementReach` must fail here. The list is
    /// injected because in a correct build nothing is stranded.
    @Test func testTheStrandedWarningReachesTheLog() async {
        let log = LogCapture()

        let defaults = ScratchDefaults("PaneBarMigrationTests-reach-stranded")
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        PaneBarMigration.reportStoredArrangementReach(defaults: defaults, withoutARoute: [.delete])

        let written = await log.entries.last { $0.message.hasPrefix("[panebar] Delete ships") }
        // `messageBody`, because `warning` appends a " | Location: file:line / function" tail. The
        // tail names `reportStoredArrangementReach`, proving the line came from it.
        #expect(written?.messageBody == "[panebar] Delete ships on the default pane bar with no migration step,"
                + " so this stored arrangement can never show it — see PaneBarMigration")
        #expect(written?.messageLocation?.contains("reportStoredArrangementReach") == true,
                "the warning was not written by reportStoredArrangementReach")
        #expect(written?.level == .warning,
                "a control the build shipped with nowhere to land is not an informational note")
    }

    /// A bar carrying everything writes no line, and neither does an uncustomized install, the
    /// common case, or everyone would get a line per launch about nothing.
    @Test func testALaunchOnAnUntouchedBarWritesNothingAboutIt() async {
        let log = LogCapture()

        let uncustomized = ScratchDefaults("PaneBarMigrationTests-reach-fresh")
        PaneBarMigration.reportStoredArrangementReach(defaults: uncustomized)
        let complete = ScratchDefaults("PaneBarMigrationTests-reach-complete")
        complete.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        PaneBarMigration.reportStoredArrangementReach(defaults: complete)
        // After both reports, so a capture that holds it was listening across them.
        let marker = "panebar-reach-silence-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let entries = await log.entries
        // Without this the absence below would pass if the capture heard nothing at all.
        #expect(entries.contains { $0.message == marker },
                "the capture never saw this test's own line — this absence proves nothing")
        #expect(!entries.contains { $0.message.hasPrefix("[panebar] The stored pane-bar arrangement") },
                "a bar that carries every shipped control was reported as missing something")
    }

    /// The stranded-control warning, driven by an injected list because a correct build strands
    /// nothing.
    @Test func testTheStrandedControlWarningNamesTheControlAndOnlyWhenItIsMissing() {
        let bar = PaneBarArrangement(encoded: "flexibleSpace,scan,sort")
        // Two of them: the verb and pronoun agree with the count.
        #expect(PaneBarMigration.unreachableMessage(for: bar, withoutARoute: [.delete, .newFolder])
                == "[panebar] New Folder, Delete ship on the default pane bar with no migration step,"
                + " so this stored arrangement can never show them — see PaneBarMigration")
        // Nothing stranded, nothing said: a correct build.
        #expect(PaneBarMigration.unreachableMessage(for: bar, withoutARoute: []) == nil)
        // Stranded in the code but on this bar: this user can see it, so there's nothing to say.
        let carriesIt = PaneBarArrangement(encoded: "flexibleSpace,scan,delete")
        #expect(PaneBarMigration.unreachableMessage(for: carriesIt, withoutARoute: [.delete]) == nil)
    }

    /// The omission line doesn't nag about a declined control. `omissions` is the default bar minus
    /// the stored one, so `.delete` is in it for every bar customized before Delete shipped; naming
    /// it would tell those users, every launch, to put back a control deliberately withheld.
    @Test func testTheOmissionLineLeavesOutControlsThatDeclinedAStep() {
        #expect(PaneBarMigration.declinedControls == [.delete],
                "the fixture below is written around Delete being the one decline")
        // Everything except the declined control: most bars customized before Delete shipped.
        let allButDelete = PaneBarArrangement(PaneBarArrangement.default.items.filter { $0 != .delete })
        #expect(!allButDelete.items.contains(.delete), "the fixture must really omit it")
        #expect(PaneBarMigration.omissionMessage(for: allButDelete) == nil,
                "a bar missing only the declined control was reported as missing something")
        // …and the line still names everything else, so Delete was left out, not the line
        // switched off.
        let alsoMissingSort = PaneBarArrangement(allButDelete.items.filter { $0 != .sort })
        #expect(PaneBarMigration.omissionMessage(for: alsoMissingSort)
                == "[panebar] The stored pane-bar arrangement omits Sort — put back from Customize Pane Bar…")
    }

    /// On a full bar, "put back from Customize Pane Bar…" would do nothing: `insert` refuses
    /// silently at `maxItems`, and the sheet would look broken. So a full bar is told what it would
    /// take instead.
    @Test func testAFullBarIsToldWhatItWouldTakeInstead() {
        let base = PaneBarArrangement.default.items.filter { $0 != .sort }
        let full = PaneBarArrangement(
            base + Array(repeating: .space, count: PaneBarArrangement.maxItems - base.count))
        #expect(full.items.count == PaneBarArrangement.maxItems, "the fixture must actually be full")
        #expect(PaneBarMigration.omissionMessage(for: full)
                == "[panebar] The stored pane-bar arrangement omits Sort — the bar is full at 16 items,"
                + " so nothing can go back on until something comes off")
        // One item fewer takes the ordinary advice, so the branch above is about being full.
        let roomy = PaneBarArrangement(base + Array(repeating: .space,
                                                    count: PaneBarArrangement.maxItems - base.count - 1))
        #expect(roomy.items.count == PaneBarArrangement.maxItems - 1)
        #expect(PaneBarMigration.omissionMessage(for: roomy)
                == "[panebar] The stored pane-bar arrangement omits Sort — put back from Customize Pane Bar…")
    }
}
