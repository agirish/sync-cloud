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
/// **What actually makes the log assertions here safe** — because the note that used to sit in this
/// spot credited `.serialized`, and `.serialized` is not the mechanism. It orders the tests *within
/// this suite*; the `Logger.shared` buffer is process-wide and every other suite in the run is still
/// writing into it concurrently. Three things do the work, and the suite attribute is only the
/// third:
///
/// * **A marker window.** Every read of `Logger.shared.entries` here — presence or absence — writes
///   a UUID marker first and looks only at what follows it. The buffer is capped at 1000 entries, so
///   a read without one can pass for free once a sibling suite has rolled the window past everything
///   this test wrote (`docs/flaky-tests.md`, mechanism 12).
/// * **Disjoint predicates.** The absences below look for `[panebar] The stored pane-bar
///   arrangement`, which nothing outside this file writes, so no other suite's line can land inside
///   one of these windows and no test here can contradict another's absence.
/// * `.serialized` on top of both, which keeps the windows short rather than making them sound.
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

        #expect(PaneBarMigration.apply(defaults: defaults) == .rewritten(added: [.search], removed: []),
                "the migration must report Search as what it added, or the launch line names the wrong control")

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
        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged, "already stamped — nothing to do")
        // **The whole stored string, not `contains`.** Its six siblings compare the encoding, and
        // this site compared only Search's absence — so a second run that reordered the bar, or
        // dropped some OTHER control, satisfied it. `contains` is the wrong question for a test
        // whose subject is "the migration left this bar alone": the interesting failure is a
        // rewrite, and a rewrite is exactly what a one-item check cannot see.
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == "flexibleSpace,scan,sort",
                "the stored bar was rewritten by a run that reported doing nothing")
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
        // EMPTY, for the same reason `testAFullBarIsLeftAloneAndSaysSo` expects empty: the return
        // value is what this run put onto a stored arrangement, and there is no stored arrangement.
        // This expected a non-empty answer and so held the return value to the opposite contract
        // from its sibling — which is how the app came to log a migration on every uncustomized
        // install.
        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged)
        #expect(defaults.string(forKey: PaneBar.arrangementKey) == nil, "nothing to migrate, nothing written")
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == PaneBarMigration.currentVersion)
    }

    /// **A bar that is already full cannot take a migrated control, and the migration must say so.**
    /// `PaneBarArrangement.insert` refuses at `maxItems` and refuses SILENTLY, and spacers are
    /// repeatable, so a 16-item bar is something a user can actually build. The first version set a
    /// `changed` flag beside the `insert` call and so reported a migration that had not happened,
    /// rewriting the arrangement with identical contents. The result is compared now, not assumed.
    ///
    /// Over `migratedControls` rather than over Search, so the next step joins this by construction.
    /// The route tests below are the only other place a step is exercised, and their fixture is the
    /// ten-item default minus one control — comfortably short of the cap, so the refusal this test
    /// is named for is a state nothing else here can reach.
    @Test func testAFullBarIsLeftAloneAndSaysSo() {
        #expect(!PaneBarMigration.migratedControls.isEmpty, "no step to refuse — this would be vacuous")
        for control in PaneBarMigration.migratedControls {
            let defaults = ScratchDefaults("PaneBarMigrationTests-full-\(control.rawValue)")
            // Sixteen items, none of them `control` — spacers make the length reachable.
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
            // …and it is still STAMPED, so it does not retry every launch for a bar it cannot help.
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
        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged)
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
    /// answers whether the migration puts it back **where the shipped default puts it**.
    ///
    /// The fixture is a *stored, pre-existing* arrangement — the whole point — and it is checked
    /// for actually omitting the control before the migration runs, since a fixture that already
    /// carried it would answer true for every control and this helper would be a rubber stamp.
    ///
    /// **`contains` was the whole answer here, and containment is the wrong question.** A step that
    /// inserted at index 0 would land the control on the *leading* side of the flexible space — a
    /// different group of the bar from the one the design put it in, on a bar the user arranged —
    /// and this helper said yes. So the position is checked too, against the shipped default rather
    /// than against a literal: for every other item the bar carries, the migrated control must fall
    /// on the same side of it as `PaneBarArrangement.default` does. The flexible space is one of
    /// those items, which is what makes the index-0 mistake fail here.
    ///
    /// Not checked, deliberately: whether the control survives the first layout rung. An appended
    /// control is the first thing `PaneBarLayout.plan` sheds, and for Search that is the DESIGN —
    /// "the narrowest pane gives up the magnifier first", because it is the one control here with a
    /// keyboard equivalent. An assertion that it survives rung 1 would fail today, on correct code.
    ///
    /// Also not here: a second run from a bar stamped at `currentVersion - 1`, which is the shape a
    /// "step gated above the version" fixture would want. `currentVersion` is 1, so that stamp is 0
    /// and the run would be byte-for-byte this one — a duplicate that cannot fail.
    /// `testNoMigrationStepIsGatedAboveTheCurrentVersion` binds that hazard instead, and does catch
    /// it.
    private func migrationPlaces(_ control: PaneBarItem) throws -> Bool {
        let defaults = ScratchDefaults("PaneBarMigrationTests-route-\(control.rawValue)")
        let stored = PaneBarArrangement(PaneBarArrangement.default.items.filter { $0 != control })
        #expect(!stored.items.contains(control),
                "the fixture for \(control.displayName) still carries it, so this answer means nothing")
        defaults.set(stored.encoded, forKey: PaneBar.arrangementKey)
        // Never stamped, i.e. a bar last written before the migration mechanism ran at all.
        #expect(defaults.integer(forKey: PaneBar.migrationKey) == 0)

        PaneBarMigration.apply(defaults: defaults)

        let after = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "")
        guard let landed = after.items.firstIndex(of: control) else { return false }

        // Nothing else moved. A migration that reshuffles a bar someone arranged is worse than the
        // problem it fixes, and `contains` cannot see it.
        #expect(after.items.filter { $0 != control } == stored.items,
                "migrating \(control.displayName) disturbed the rest of the bar: \(after.encoded)")

        // …and it landed in the same relative order the shipped default carries it in. `#require`
        // rather than `#expect` for the index reads: `#expect` records and continues, and a
        // comparison built on an index that is not there is how a failing assertion becomes a
        // crashed test host.
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
        // The loop above `continue`s, so this is what says it ran. The flexible space is the item
        // that makes it worth running at all.
        #expect(compared == after.items.count - 1,
                "the ordering check skipped \(after.items.count - 1 - compared) of the bar's items")
        #expect(after.items.contains(.flexibleSpace),
                "the fixture lost its flexible space, so the side-of-the-space check compared nothing")
        return true
    }

    /// **Every control on the shipped bar must be able to reach a bar someone customized**, and
    /// this names the one that cannot.
    ///
    /// Three routes, and a control has to be on exactly one of them: it shipped before this
    /// mechanism existed (so every stored bar already had the chance to carry it), a migration step
    /// places it (verified by running the migration, not by reading a list), or it declines a step
    /// deliberately. The declines are named here as well as in the source so a new control cannot
    /// join them with a one-line edit.
    @Test func testEveryControlOnTheDefaultBarHasARouteOntoACustomizedBar() throws {
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

        // **The accounting, in one comparison, and it goes both ways.** The loop below can only
        // check controls that reach it; this checks the lists themselves. Left to right: a control
        // on the shipped bar and on no route is the hazard this whole mechanism exists for. Right
        // to left: a control on a route but NOT on the shipped bar is a claim about something that
        // does not ship — and it is the one direction the loop is structurally blind to, because
        // `migrationPlaces` would build its fixture by removing a control the default does not
        // carry, get back the default bar, pass its `!contains` guard vacuously and answer true.
        let shipped = Set(PaneBarArrangement.default.items.filter { !$0.isSpacer })
        let unrouted = shipped.subtracting(PaneBarMigration.routedControls).map(\.displayName).sorted()
        let unshipped = PaneBarMigration.routedControls.subtracting(shipped).map(\.displayName).sorted()
        let disagreement = "the routes and the shipped bar disagree — on the bar with no route: "
            + "\(unrouted); on a route but not on the bar: \(unshipped)"
        #expect(PaneBarMigration.routedControls == shipped, "\(disagreement)")
        // The same fact in the form the RUNTIME warning reads, so the log line cannot be armed
        // against a different notion of "stranded" than the one above. (This was a test of its own,
        // `testNoShippedControlIsStranded`; it could only fail when this one did, and a second name
        // for one fact is a second thing to keep in step.)
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

        // **The loop `continue`s twice, so after the skips only `.search` is left — and nothing
        // said the body had run at all.** Its sibling below guards itself with
        // `!migratedControls.isEmpty`; this is the same guard, and it names the member so that
        // "every control got skipped" cannot read as "every control has a route".
        let neverRan = "the route loop never reached Search — every shipped control was skipped as "
            + "baseline or declined, so this test proved nothing about any of them"
        #expect(checked.contains(.search), "\(neverRan)")
    }

    /// The other direction: `migratedControls` is a *claim*, and this is what stops it drifting
    /// away from the steps in `apply`. A control named there that no step places would make the
    /// test above pass for a control with no route at all.
    @Test func testEveryControlTheMigrationClaimsToPlaceActuallyLands() throws {
        #expect(!PaneBarMigration.migratedControls.isEmpty,
                "no control is migrated at all — the accounting above would then be vacuous")
        for control in PaneBarMigration.migratedControls {
            #expect(try migrationPlaces(control),
                    "PaneBarMigration.migratedControls names \(control.displayName), but running the migration on a stored bar without it does not put it back")
        }
        // A control cannot be on two routes at once: "we migrate it" and "we deliberately do not"
        // is a contradiction, and "it predates the mechanism" plus "a step adds it" is a step that
        // can never have anything to do.
        #expect(PaneBarMigration.migratedControls.isDisjoint(with: PaneBarMigration.declinedControls))
        #expect(PaneBarMigration.migratedControls.isDisjoint(with: PaneBarMigration.baselineControls))
        #expect(PaneBarMigration.baselineControls.isDisjoint(with: PaneBarMigration.declinedControls))
    }

    /// **A step gated above `currentVersion` is dead for exactly the population the mechanism
    /// serves, and every behavioural test here is blind to it.**
    ///
    /// Change the Search step's `from < 1` to `from < 2` and leave `currentVersion` at 1: the whole
    /// suite stays green. Every fixture above starts from a bar that was never stamped, where
    /// `0 < 2` and `0 < 1` are the same answer — but a control that ships *now* arrives at installs
    /// already stamped at 1, which is the one population that needs the step, and `apply` returns on
    /// its guard line before reaching it. That is "add a step, forget to bump `currentVersion`", and
    /// it is silent. The route test's own failure text says "bump currentVersion"; nothing bound the
    /// second half, and `testTheSearchStampIsUnchanged` catches a version bumped WITHOUT a step, not
    /// a step added without a bump.
    ///
    /// A source scan, because the population it is about does not exist yet: no control today is
    /// gated above 1, so there is no fixture that behaves differently. What can be checked is the
    /// relationship between the literals — every step's gate must be one the stamp actually passes.
    /// Comment lines are stripped first, since the prose right above quotes `from < 2`.
    @Test func testNoMigrationStepIsGatedAboveTheCurrentVersion() throws {
        let source = try Self.arrangementSource()
        var gates: [Int] = []
        var rest = Substring(source)
        while let hit = rest.range(of: "if from < ") {
            let digits = rest[hit.upperBound...].prefix(while: \.isNumber)
            if let gate = Int(digits) { gates.append(gate) }
            rest = rest[hit.upperBound...]
        }
        // The anchor: Search's step is gated at 1, and a scan that cannot find it is reading the
        // wrong text and would report "no gate is too high" for free.
        let noAnchor = "no migration step gated `if from < 1` was found in PaneBarArrangement.swift "
            + "— either Search's step is gone or this scan no longer matches how a step is written, "
            + "and the check below is vacuous either way. Found: \(gates)"
        #expect(gates.contains(1), "\(noAnchor)")
        let highest = gates.max().map(String.init) ?? "nothing"
        let outOfStep = "the newest migration step is gated at \(highest) but currentVersion is "
            + "\(PaneBarMigration.currentVersion). A step gated ABOVE the current version never runs "
            + "for a stamped install — every bar already migrated once, which is everyone the new "
            + "step is for — and one gated BELOW it is a step nothing can reach. Bump currentVersion "
            + "in the same edit as the step."
        #expect(gates.max() == PaneBarMigration.currentVersion, "\(outOfStep)")
    }

    /// The derivation behind the runtime warning, proven to derive something.
    ///
    /// In a correct build `controlsWithoutARoute` is empty, so every honest check of it compares
    /// against `[]` — and a version of it hard-wired to return `[]` would pass all of them while
    /// leaving `unreachableMessage` permanently unreachable. Handing the inputs in is what
    /// distinguishes the two: with no routes at all it must name the entire shipped bar, and with
    /// one route removed it must name exactly that route's members.
    @Test func testTheRouteDerivationNamesWhatTheRoutesDoNotCover() {
        // Written out, not recomputed from `default.items.filter { !$0.isSpacer }` — that is the
        // derivation under test, and comparing it with itself would pass for any filter at all,
        // including one that returned its input.
        let shipped: [PaneBarItem] = [.viewMode, .collapse, .backForward, .scan, .newFolder, .sort,
                                      .hiddenFiles, .preview, .delete, .search]
        #expect(PaneBarArrangement.default.encoded == "flexibleSpace,viewMode,collapse,backForward,"
                + "scan,newFolder,sort,hiddenFiles,preview,delete,search",
                "the shipped bar changed; the literal below is what this test is measuring against")
        let withNoRoutes = PaneBarMigration.controlsWithoutARoute(shipping: .default, routed: [])
        let namedInstead = "with no routes declared, every shipped control is stranded — this named "
            + "\(withNoRoutes.map(\.displayName))"
        #expect(withNoRoutes == shipped, "\(namedInstead)")
        // The spacer is in that encoded string and not in the list above: spacers are layout, not
        // ability, and are exempt even when nothing routes them.
        #expect(PaneBarArrangement.default.items.contains(.flexibleSpace),
                "the default bar has no spacer, so the exemption above was not exercised")
        // And dropping ONE route strands exactly its members — the shape the mechanism is for.
        #expect(PaneBarMigration.controlsWithoutARoute(
                    shipping: .default,
                    routed: PaneBarMigration.routedControls.subtracting([.search])) == [.search])
    }

    /// The two wirings behind the stranded warning that only source can state.
    ///
    /// `unreachableMessage` is tested against an injected list because in a correct build no fixture
    /// can strand a control; the price of that seam is that a caller could hand it `[]` and the
    /// warning would be dead with every test still green. Same for the property it comes from: it
    /// could stop consulting the routes. Neither is checkable from behaviour while the honest answer
    /// is empty, so both are pinned here — with the declarations required first, so a rename fails
    /// loudly rather than making this pass by finding nothing.
    @Test func testTheStrandedWarningIsWiredToTheRealRouteList() throws {
        let source = try Self.arrangementSource()
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

    /// Reads `PaneBarArrangement.swift`, comment lines stripped.
    ///
    /// Stripped because the prose in that file and in this one quotes the very literals being
    /// scanned for; a scan that counted comments would answer its own questions.
    private static func arrangementSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)                 // …/Tests/Dashboard/<this>.swift
            .deletingLastPathComponent()                          // …/Tests/Dashboard
            .deletingLastPathComponent()                          // …/Tests
            .deletingLastPathComponent()                          // …/Dashboard
            .appendingPathComponent("Sources/Dashboard/PaneBarArrangement.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read PaneBarArrangement.swift — every scan here would be vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The launch line names what this run added, and a second step joins it by construction.**
    ///
    /// `SyncCloudApp` used to be handed a `Bool` and write the literal `"added Search to a stored
    /// pane-bar arrangement"`. That was a true sentence for exactly as long as Search was the only
    /// step there could be: the second step to ship would have left every migrating launch claiming
    /// Search for a control it did not add, in the file a launch is verified through, and nothing
    /// anywhere would have said so — the same class of stale claim `reportStoredArrangementReach`
    /// exists to keep out of that file.
    ///
    /// Both ends are checked here because the sentence is assembled from two pieces. `apply` is
    /// **run**, not read off `migratedControls`, so a step that claims a control it does not place
    /// fails here rather than producing a confident line about nothing; and `migrationMessage` is
    /// handed exactly what `apply` answered. A control added to `migratedControls` with a step in
    /// `apply` is picked up by the loop below and its name required in the line, so nobody has to
    /// remember the call site.
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

        // **Two at once, as a literal.** This is the case the old line could not express and the
        // one a second step creates — a bar arranged before either control shipped gains both on
        // the same launch. Written out rather than recomputed from `names`, which would agree with
        // itself whatever it said.
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [.search, .delete], removed: []))
                == "[panebar] rewrote a stored pane-bar arrangement: added Search, Delete",
                "the line cannot name more than one control, which is the whole reason it stopped being a literal")
        // Nothing happened, nothing said — and this is now the ONLY outcome that may go unlogged:
        // every launch after the one that migrated, and every install that never customized its
        // bar. `.rewritten` with nothing nameable is a different value and is covered by
        // `everyRewriteLogsSomethingEvenWhenItCannotNameWhatChanged`.
        #expect(PaneBarMigration.migrationMessage(for: .unchanged) == nil,
                "a launch that migrated nothing still writes a line claiming it did")
    }

    /// **The hole this replaced: a rewrite that logs nothing.**
    ///
    /// `apply` used to answer `[PaneBarItem]` — the controls it had put onto the bar — and its doc
    /// promised that was "empty when nothing was rewritten". The list is derived by comparing the
    /// migrated items against the stored ones, so it is empty for a **removal**, for a **reorder**,
    /// and for a **repeatable insertion** (spacers repeat, which `PaneBarArrangement.insert` says
    /// in as many words). Each of those writes the arrangement back and then reports `[]`, so the
    /// message was `nil` and `~/sync-cloud.log` — the file a launch is verified through — said
    /// nothing whatever about a bar that had just been rewritten under its owner.
    ///
    /// Three of the four shapes a second migration step can take are in that hole, and the entire
    /// stated purpose of returning something richer than a `Bool` was the day a second step ships.
    ///
    /// **Fixtures built by hand, deliberately NOT from `PaneBarArrangement.default`.** The route
    /// helpers in this file take the shipped default minus one control, which is the pattern that
    /// cannot see a new case in a persisted user-arrangeable collection — the fixture moves with
    /// the collection, so the new case is in it before anyone writes a test for it. Nothing here
    /// enumerates controls at all: the subject is the SHAPE of a change, which is control-agnostic,
    /// so a control added tomorrow neither helps nor hides.
    ///
    /// Fed to `PaneBarMigration.outcome` directly because `apply` cannot produce these shapes —
    /// the one step that ships is a non-repeatable pure addition. `apply` routes its single write
    /// through this same function (`theMigrationRoutesItsOwnAnswerThroughOutcome` below), so
    /// binding it here binds every future step's rewrite too.
    @Test func everyRewriteLogsSomethingEvenWhenItCannotNameWhatChanged() {
        // The three shapes, each stated as its own before/after so a reader can check the premise.
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
            // The point of the whole change. Not "names what it did" — a reorder has no name — but
            // "says the bar was rewritten", which is the fact that must never be conditional on
            // the migration being able to describe its own work.
            let line = PaneBarMigration.migrationMessage(for: outcome)
            #expect(line != nil, "a \(shape) rewrote the bar and the launch log said nothing")
            #expect(line?.contains("rewrote a stored pane-bar arrangement") == true,
                    "the \(shape) line does not say the bar was rewritten: \(line ?? "nil")")
        }

        // The two nameable shapes say what they can, on top of the same stem — so one grep finds
        // every rewrite whether or not it could be named.
        #expect(PaneBarMigration.outcome(before: [.scan, .sort], after: [.scan, .sort, .search])
                == .rewritten(added: [.search], removed: []))
        #expect(PaneBarMigration.outcome(before: [.scan, .sort], after: [.scan])
                == .rewritten(added: [], removed: [.sort]))
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [], removed: [.sort]))
                == "[panebar] rewrote a stored pane-bar arrangement: removed Sort")
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [.search], removed: [.sort]))
                == "[panebar] rewrote a stored pane-bar arrangement: added Search, removed Sort")
        // The unnameable rewrite's whole sentence, as a literal — this is the string that used to
        // not exist.
        #expect(PaneBarMigration.migrationMessage(for: .rewritten(added: [], removed: []))
                == "[panebar] rewrote a stored pane-bar arrangement")

        // A repeatable item added twice is still named once: "added Space, Space" is not a sentence.
        #expect(PaneBarMigration.outcome(before: [.scan], after: [.scan, .space, .space])
                == .rewritten(added: [.space], removed: []))
    }

    /// The call-site half of the test above. A rule extracted so it can be tested is one revert
    /// away from being a well-tested function nothing calls — and `outcome` is the only thing that
    /// decides whether `apply` writes at all, so this checks the two answers really are one answer.
    ///
    /// Run through `apply` on the one shape it can actually produce, and required to equal what
    /// `outcome` says about the same before/after. A version of `apply` that had kept its own
    /// derivation beside the write would pass every other test in this file and fail here.
    @Test func theMigrationRoutesItsOwnAnswerThroughOutcome() {
        let defaults = ScratchDefaults("PaneBarMigrationTests-routes-through-outcome")
        let before = PaneBarArrangement(encoded: "flexibleSpace,scan,sort,hiddenFiles").items
        #expect(!before.contains(.search), "the fixture already carries Search — nothing would migrate")
        defaults.set(PaneBarArrangement(before).encoded, forKey: PaneBar.arrangementKey)

        let applied = PaneBarMigration.apply(defaults: defaults)
        let after = PaneBarArrangement(encoded: defaults.string(forKey: PaneBar.arrangementKey) ?? "").items
        #expect(after != before, "the fixture did not migrate, so this comparison is vacuous")
        // Recomputed from the two bars that were actually stored, NOT from `applied` — a check of
        // `applied` against itself would agree whatever either side said.
        #expect(applied == PaneBarMigration.outcome(before: before, after: after),
                "`apply` reported \(applied) but `outcome` reads the same rewrite as \(PaneBarMigration.outcome(before: before, after: after))")
        #expect(PaneBarMigration.migrationMessage(for: applied) != nil,
                "the one rewrite `apply` can produce logs nothing")
    }

    // MARK: - What a launch writes down about the bar

    /// **The already-stamped install is the one that has to be reported on**, and it is the one
    /// `apply` returns from on its second line without looking at the arrangement at all. Every
    /// launch after the one that migrated is that install, so a bar missing a shipped control is
    /// silent forever unless the report runs independently of whether anything migrated.
    @Test func testAnAlreadyStampedLaunchStillSaysWhatTheBarCannotShow() async {
        let marker = "panebar-reach-stamped-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let defaults = ScratchDefaults("PaneBarMigrationTests-reach-stamped")
        defaults.set(PaneBarMigration.currentVersion, forKey: PaneBar.migrationKey)
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)

        #expect(PaneBarMigration.apply(defaults: defaults) == .unchanged, "nothing to migrate on this path")
        PaneBarMigration.reportStoredArrangementReach(defaults: defaults)
        await flushLog()

        // The literal, not a recomputation: a line assembled from the same call the source makes
        // would agree with itself whatever it said. Delete is NOT in it — see `omissionMessage`: a
        // control that declines a migration step is absent from these bars by design, and telling
        // this user to put it back, every launch, is advice about a decision rather than a defect.
        let entries = Logger.shared.entries
        #expect(entries.contains { $0.message == marker },
                "the log window rolled past the marker — read the entries sooner")
        #expect(entries.drop(while: { $0.message != marker }).contains {
            $0.message == "[panebar] The stored pane-bar arrangement omits View, Collapse Pane, "
                + "Back/Forward, New Folder, Hidden Files, Preview, Search"
                + " — put back from Customize Pane Bar…"
        }, "a launch on a bar missing seven shipped controls wrote nothing about it")
    }

    /// **`apply` writes no report of its own**, which is the whole of the fix for a duplicated one.
    ///
    /// It used to carry `defer { reportStoredArrangementReach(…) }`, and its one production caller
    /// is inside `App.init` — which SwiftUI may re-run, and which `SyncCloudApp` says so about three
    /// lines from the call. Every other migration in that `init` is annotated "the repeat App.init
    /// calls noted above are harmless" because a repeat writes nothing; this one wrote its whole
    /// report again, so somebody who removed a control two releases ago was told about it once per
    /// rebuild of the scene, forever. The report is the delegate's now — `applicationDidFinishLaunching`
    /// fires exactly once per process, which is why the launch breadcrumb already lives there.
    ///
    /// This is the assertion that keeps it out: re-adding the `defer` while the delegate still calls
    /// it is a double line per launch, and that is what fails here.
    @Test func testTheMigrationItselfWritesNoReachReport() async {
        let marker = "panebar-reach-not-from-apply-\(UUID().uuidString)"
        Logger.shared.info(marker)

        // A bar missing almost everything — if `apply` reported at all, this is the fixture that
        // would make it shout.
        let stamped = ScratchDefaults("PaneBarMigrationTests-reach-apply-stamped")
        stamped.set(PaneBarMigration.currentVersion, forKey: PaneBar.migrationKey)
        stamped.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        PaneBarMigration.apply(defaults: stamped)
        // …and the migrating path too, since a `defer` fires on every way out.
        let migrating = ScratchDefaults("PaneBarMigrationTests-reach-apply-migrating")
        migrating.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        #expect(PaneBarMigration.apply(defaults: migrating) == .rewritten(added: [.search], removed: []),
                "the fixture must really migrate")
        await flushLog()

        let entries = Logger.shared.entries
        #expect(entries.contains { $0.message == marker },
                "the log window rolled past the marker — this absence proves nothing")
        let since = entries.drop(while: { $0.message != marker })
        let reportedFromApply = "PaneBarMigration.apply wrote the reach report; App.init can be "
            + "re-run, so it would repeat for the same launch — the delegate owns this line"
        #expect(!since.contains { $0.message.hasPrefix("[panebar] The stored pane-bar arrangement") },
                "\(reportedFromApply)")
        // The positive control for the absence: the same fixture, reported deliberately, does write.
        // Without it "apply said nothing" would also be the reading if the report were gone entirely.
        PaneBarMigration.reportStoredArrangementReach(defaults: stamped)
        await flushLog()
        #expect(Logger.shared.entries.drop(while: { $0.message != marker }).contains {
            $0.message.hasPrefix("[panebar] The stored pane-bar arrangement omits")
        }, "nothing reports this bar at all, so the absence above says nothing about where the report lives")
    }

    /// **The stranded warning actually reaches the log**, which nothing checked.
    ///
    /// Deleting the whole `if let line = unreachableMessage(…) { Logger.shared.warning(line) }` block
    /// left the suite green: `unreachableMessage` was exercised as a pure function with an injected
    /// list, and no test ever called the thing that calls it. The injected list is what makes this
    /// reachable at all — in a correct build nothing is stranded, so the branch that matters is the
    /// branch no honest fixture can produce.
    @Test func testTheStrandedWarningReachesTheLog() async {
        let marker = "panebar-reach-stranded-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let defaults = ScratchDefaults("PaneBarMigrationTests-reach-stranded")
        defaults.set("flexibleSpace,scan,sort", forKey: PaneBar.arrangementKey)
        PaneBarMigration.reportStoredArrangementReach(defaults: defaults, withoutARoute: [.delete])
        await flushLog()

        let since = Logger.shared.entries.drop(while: { $0.message != marker })
        #expect(Logger.shared.entries.contains { $0.message == marker },
                "the log window rolled past the marker — read the entries sooner")
        let written = since.last { $0.message.hasPrefix("[panebar] Delete ships") }
        // `messageBody`, because `warning` appends its own " | Location: file:line / function" tail
        // — which is itself worth reading here: it names `reportStoredArrangementReach`, so the tail
        // says the line came from the reporting function rather than from a test calling
        // `unreachableMessage` directly.
        #expect(written?.messageBody == "[panebar] Delete ships on the default pane bar with no migration step,"
                + " so this stored arrangement can never show it — see PaneBarMigration")
        #expect(written?.messageLocation?.contains("reportStoredArrangementReach") == true,
                "the warning was not written by reportStoredArrangementReach")
        #expect(written?.level == .warning,
                "a control the build shipped with nowhere to land is not an informational note")
    }

    /// A bar carrying everything writes no line — the rule that keeps this proportional. An
    /// uncustomized install has no stored arrangement at all and is the common case; a line there
    /// would be one per launch for everybody, about nothing.
    @Test func testALaunchOnAnUntouchedBarWritesNothingAboutIt() async {
        let marker = "panebar-reach-silence-\(UUID().uuidString)"
        Logger.shared.info(marker)

        let uncustomized = ScratchDefaults("PaneBarMigrationTests-reach-fresh")
        PaneBarMigration.reportStoredArrangementReach(defaults: uncustomized)
        let complete = ScratchDefaults("PaneBarMigrationTests-reach-complete")
        complete.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        PaneBarMigration.reportStoredArrangementReach(defaults: complete)
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
                == "[panebar] Delete ships on the default pane bar with no migration step,"
                + " so this stored arrangement can never show it — see PaneBarMigration")
        // Two of them, which is the case "ship(s) … can never show it" could not write: the hedge
        // read as a parenthesis for one control and as an error for two, in a line someone reads
        // while holding a bug report.
        #expect(PaneBarMigration.unreachableMessage(for: bar, withoutARoute: [.delete, .preview])
                == "[panebar] Preview, Delete ship on the default pane bar with no migration step,"
                + " so this stored arrangement can never show them — see PaneBarMigration")
        // Nothing stranded, nothing said — the state of a correct build.
        #expect(PaneBarMigration.unreachableMessage(for: bar, withoutARoute: []) == nil)
        // Stranded in the code but present on this bar: this user can see it, so there is nothing
        // to tell them. Without this the warning would fire for every install on a bad build,
        // including the ones the defect cannot reach.
        let carriesIt = PaneBarArrangement(encoded: "flexibleSpace,scan,delete")
        #expect(PaneBarMigration.unreachableMessage(for: carriesIt, withoutARoute: [.delete]) == nil)
    }

    /// **The omission line does not nag for a control that declined a step.**
    ///
    /// `omissions` is the default bar minus the stored one, so `.delete` is in it for every bar
    /// customized before Delete shipped — which is every customized bar there is. Naming it told
    /// those users to "put back" a control the design deliberately withheld, once per launch and
    /// forever, about a state that is neither their doing nor a defect. The declines are the one
    /// group whose absence is the intended outcome.
    @Test func testTheOmissionLineLeavesOutControlsThatDeclinedAStep() {
        #expect(PaneBarMigration.declinedControls == [.delete],
                "the fixture below is written around Delete being the one decline")
        // A bar that carries everything EXCEPT the declined control: the majority state of every
        // install that customized its bar before Delete shipped, and the one that used to be told
        // off for it on every launch.
        let allButDelete = PaneBarArrangement(PaneBarArrangement.default.items.filter { $0 != .delete })
        #expect(!allButDelete.items.contains(.delete), "the fixture must really omit it")
        #expect(PaneBarMigration.omissionMessage(for: allButDelete) == nil,
                "a bar missing only the declined control was reported as missing something")
        // …and the line still names everything else, so this is "Delete was left out of the line",
        // not "the line was switched off" — the difference an absence assertion cannot see.
        let alsoMissingSort = PaneBarArrangement(allButDelete.items.filter { $0 != .sort })
        #expect(PaneBarMigration.omissionMessage(for: alsoMissingSort)
                == "[panebar] The stored pane-bar arrangement omits Sort — put back from Customize Pane Bar…")
    }

    /// **On a full bar, "put back from Customize Pane Bar…" is advice that does nothing.**
    ///
    /// `PaneBarArrangement.insert` refuses at `maxItems` and refuses silently, so someone following
    /// that instruction drags the control on and watches nothing happen — which is worse than
    /// saying nothing, because it reads as the sheet being broken.
    @Test func testAFullBarIsToldWhatItWouldTakeInstead() {
        let base = PaneBarArrangement.default.items.filter { $0 != .sort }
        let full = PaneBarArrangement(
            base + Array(repeating: .space, count: PaneBarArrangement.maxItems - base.count))
        #expect(full.items.count == PaneBarArrangement.maxItems, "the fixture must actually be full")
        #expect(PaneBarMigration.omissionMessage(for: full)
                == "[panebar] The stored pane-bar arrangement omits Sort — the bar is full at 16 items,"
                + " so nothing can go back on until something comes off")
        // The same bar with one item off takes the ordinary advice, so the branch above is a
        // property of being full and not of this fixture.
        let roomy = PaneBarArrangement(base + Array(repeating: .space,
                                                    count: PaneBarArrangement.maxItems - base.count - 1))
        #expect(roomy.items.count == PaneBarArrangement.maxItems - 1)
        #expect(PaneBarMigration.omissionMessage(for: roomy)
                == "[panebar] The stored pane-bar arrangement omits Sort — put back from Customize Pane Bar…")
    }
}
