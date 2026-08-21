import Testing
import Foundation
import CoreGraphics
@testable import Sync

/// ``FolderSurveyBuilder`` re-derived against the **hand-built** folder profile and the real tree
/// it describes — the only test here that can say whether the rules are right.
///
/// ## Why a fixture cannot settle this
///
/// Every rule in the builder is a claim about one person's 3,013-folder corpus: that `Archive`
/// names a role only on the folder that carries it, that a month word is noise in a filename and a
/// subject in a folder name, that a component naming two people names neither. Those are not
/// derivable from first principles and a synthetic tree cannot refute them — it can only replay
/// whatever the author already believed. The hand-built profile is an independent answer written by
/// a different process (an out-of-repo Python script, over the same tree), so comparing against it
/// is the one place the rules can actually be wrong.
///
/// ## What the thresholds mean, and why they are not 100%
///
/// Two sources of disagreement are expected and neither is a defect:
///
/// - **Tree drift.** The profile was written 2026-08-09 and the tree has moved since — folders
///   added, files filed. So the comparison runs over the *intersection* of paths, and even there a
///   folder whose files changed can legitimately produce different anchors.
/// - **Judgement the walk cannot see.** Six folders refuse new files for the recorded reason
///   `outbound-pack` — a fact about what the folder is *for*, which no walk re-derives. The builder
///   does not claim them and never should.
///
/// The thresholds below are the measured numbers minus a small margin. They are floors on
/// *agreement*, so the failure they exist to catch is a rule quietly rotting — not the tree moving.
///
/// ## Why machine-pinned as well as gated on the profile
///
/// `.enabled(if:)` alone is not enough and CI has already proved it: the self-hosted runner is this
/// same Mac and the same user, so the profile is right there and the suite runs in full — under
/// Rosetta, where a walk of this tree measured 10.8s against 1.05s natively, starving the
/// timing-sensitive suites running beside it. See ``MachinePinnedReason/liveProfile``.
///
/// ## Why the display has to be awake
///
/// The walk is of a real iCloud-backed `~/Documents`, from a lazy `static let`, so every test here
/// blocks on it — and an iCloud walk makes no progress at all while the display is asleep. Left
/// ungated, an unattended `swift test` sits in that static indefinitely: four matched cases on
/// 2026-08-13, one of which ran 8,888s with the main thread idle at 0% CPU. That is a run with no
/// verdict, which `docs/flaky-tests.md` mechanism 8 ranks below a red one. CI never saw it —
/// `liveProfile` is in `SYNCCLOUD_SKIP_MACHINE_PINNED` there — so the exposure was local runs only,
/// which is exactly where nobody is watching.
/// **Always runs, and exists so that a skipped ground truth is visible in the run rather than
/// inferable from an absence.**
///
/// The suite below is gated three ways, and a `.enabled(if:)` that answers false produces no test
/// results at all — so the one suite that checks the survey rules against a real tree can be absent
/// from a green run and nothing in that run says so. On this machine the display gate closes on an
/// ordinary working morning (`pmset -g log`: off 09:06, on 09:20, off 09:30, on 09:46), so the
/// absence is routine rather than exotic. `docs/flaky-tests.md` mechanism 8 ranks a run with no
/// verdict below a red one, and this is that one level up: a *suite* with no verdict.
///
/// Two tests, and the split is the point. The first pins the report's own logic across all four gate
/// combinations, so the line cannot come to say "ran" for a closed gate. The second emits the real
/// line and asserts it against the gates it read — which is what stops this from being a probe that
/// prints something nobody ever checks.
@Suite struct FolderSurveyGroundTruthGateTests {

    @Test func theGateLineNamesWhicheverGateIsClosed() {
        typealias G = FolderSurveyGroundTruth
        func gateLine(liveProfile: Bool, displayAwake: Bool) -> String {
            G.gateLine(excluded: false, liveProfile: liveProfile, displayAwake: displayAwake)
        }
        // The exclusion outranks both, including the combination that would otherwise say RAN —
        // which is the case that was actually reachable, and the only one CI ever takes.
        for (profile, awake) in [(true, true), (true, false), (false, true), (false, false)] {
            let line = G.gateLine(excluded: true, liveProfile: profile, displayAwake: awake)
            #expect(line.hasPrefix("SKIPPED"), "an excluded reason reported \(line)")
            #expect(line.contains("SYNCCLOUD_SKIP_MACHINE_PINNED"),
                    "an excluded reason must name the variable that excluded it: \(line)")
        }
        #expect(gateLine(liveProfile: true, displayAwake: true).hasPrefix("RAN"))
        // The profile is reported first because it is the suite's first gate: with no profile the
        // display's state is not why the suite said nothing, and naming it would send the next
        // reader to wake a display that was never the problem.
        #expect(gateLine(liveProfile: false, displayAwake: true).contains("no live folder profile"))
        #expect(gateLine(liveProfile: false, displayAwake: false).contains("no live folder profile"))
        #expect(gateLine(liveProfile: true, displayAwake: false).contains("display is asleep"))
        for line in [gateLine(liveProfile: false, displayAwake: true),
                     gateLine(liveProfile: true, displayAwake: false)] {
            #expect(line.hasPrefix("SKIPPED"), "a closed gate reported \(line)")
        }
    }

    @Test func theRunSaysWhetherGroundTruthRan() {
        // Read from the same gate the suite's own `.machinePinned(.liveProfile)` trait consults, so
        // the report cannot say RAN for a suite that trait has disabled.
        let excluded = MachinePinnedGate.isExcluded(.liveProfile)
        let liveProfile = LiveProfile.isAvailable
        let awake = FolderSurveyGroundTruth.displayIsAwake
        let line = FolderSurveyGroundTruth.gateLine(excluded: excluded, liveProfile: liveProfile,
                                                    displayAwake: awake)
        // stdout, because that is what a CI step log keeps. `Logger.shared.entries` is capped at
        // 1000 and shared across every suite in the package, so a line parked there is the one thing
        // this must not rely on — see mechanism 12.
        print("[ground-truth] \(line)")
        #expect(line.hasPrefix("RAN") == (!excluded && liveProfile && awake),
                "the gate report says \(line) while the gates read excluded=\(excluded) liveProfile=\(liveProfile) displayAwake=\(awake)")
    }

    /// **An unreadable directory is `isUnexplored`, not an explored empty one.**
    ///
    /// The reference walker used to answer `[]` for both, while the production walk reports
    /// `isUnexplored: true` — so a directory the test process cannot open counted as a folder that
    /// genuinely has nothing in it. Under floors expressed as *agreement ≥ 0.99* a handful of those
    /// is absorbed rather than surfaced, which is what makes it a masked miss instead of a failure.
    ///
    /// **This test lives in the ungated suite deliberately.** Put it beside the ground-truth tests
    /// and it would be skipped by the same three gates as the thing it verifies — a fix for an
    /// invisible defect, made invisible the same way. It needs no live profile and no display: a
    /// temporary tree answers it.
    ///
    /// Both directions, because a walker that marked *every* directory unexplored would satisfy the
    /// first assertion on its own.
    @Test func theReferenceWalkerTellsUnreadableFromEmpty() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gtwalk-\(UUID().uuidString)")
        let readable = root.appendingPathComponent("readable")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        // Restored before removal, or the directory cannot be deleted and the temp tree leaks.
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        var stalled = false
        // `keepGoing` is supplied so this does not consult the display: the walker's default asks
        // `displayIsAwake`, and this test has to answer the same on a machine whose screen is off.
        let nodes = FolderSurveyGroundTruth.walk(root, deadline: Date().addingTimeInterval(30),
                                                 stalled: &stalled, keepGoing: { true })
        #expect(!stalled, "the walk stalled, so neither branch below was reached")

        let byName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })
        let lockedNode = try #require(byName["locked"], "the unreadable directory is missing entirely")
        let readableNode = try #require(byName["readable"], "the readable directory is missing entirely")

        #expect(lockedNode.isUnexplored == true,
                "an unreadable directory reads as explored, so it counts as genuinely empty against the agreement floors")
        #expect(lockedNode.children?.isEmpty == true, "an unexplored directory should carry no children")
        #expect(readableNode.isUnexplored != true,
                "an ordinary empty directory is being reported as unexplored — the walker cannot tell the two apart in this direction either")
    }
}

@Suite(.enabled(if: LiveProfile.isAvailable,
                "no live folder profile on this machine — ground truth skipped"),
       .enabled(if: FolderSurveyGroundTruth.displayIsAwake,
                "the display is asleep — an iCloud walk makes no progress until it wakes"),
       .machinePinned(.liveProfile))
struct FolderSurveyGroundTruthTests {

    // MARK: - Non-vacuity: the comparison has to be looking at something

    /// The walk has to have finished, or every agreement number below is measured over a tree that
    /// was cut short. Named separately so a stall reads as itself rather than as ten rules rotting
    /// at once.
    @Test func theLiveWalkFinishedWithinItsBudget() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        let why = "the live walk gave up — it hit its \(Int(FolderSurveyGroundTruth.walkBudget))s budget or the display went to sleep under it, and every other failure in this suite is downstream of that"
        #expect(!r.walkStalled, "\(why)")
    }

    @Test func theComparisonCoversTheWholeRealProfile() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        print(r.description)
        #expect(r.shared > 2_500, "the intersection shrank — is this the real profile?")
        #expect(r.builtOnly < r.shared, "the walk found more new folders than shared ones")
        // Each field has to have real values on both sides, or its agreement is a count of nils.
        #expect(r.distinctRoles >= 6, "every role branch should be exercised by a real tree")
        #expect(r.expected(axis: "person") > 100)
        #expect(r.expected(axis: "year") > 500)
        #expect(r.expected(axis: "fiscalYear") > 100)
        #expect(r.expected(axis: "jurisdiction") > 500)
        #expect(r.foldersWithAnchors > 2_000)
        #expect(r.refusals >= 39, "the profile records 39 inbox folders that refuse files")
    }

    // MARK: - The walk

    @Test func theCountsAreTheWalk() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.rate(.fileCount) >= 0.99)
        #expect(r.rate(.subfolderCount) >= 0.99)
    }

    // MARK: - Role

    @Test func roleAgreesWithTheHandBuiltProfile() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.rate(.role) >= 0.99, r.misses(.role))
    }

    // MARK: - acceptsNewFiles

    /// Agreement is measured over the *refusals*, not over the whole field: 2,968 of 3,013 entries
    /// record nothing there, so a builder that always answered nil would score 98.5% on a naive
    /// count. What matters is that every inbox is refused and nothing else is.
    @Test func everyInboxIsRefusedAndNothingElseIs() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.refusalsCaught == r.refusals, "an inbox the builder let through")
        #expect(r.falseRefusals == 0, "a folder refused that the profile allows")
        // The six it does not claim are the `outbound-pack` refusals — judgement, not shape.
        #expect(r.rate(.acceptsNewFiles) >= 0.99)
    }

    // MARK: - Anchors

    @Test func anchorsAgreeAsAWholeListInOrder() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.rate(.anchors) >= 0.99, r.misses(.anchors))
    }

    /// The measurement that keeps the two tokenizers apart. Re-derived here rather than quoted, so
    /// the day somebody "unifies" them the number in ``FolderSurveyBuilder/anchorWords(_:)`` is not
    /// the only thing standing in the way.
    @Test func theRoutersTokenizerWouldBeMuchWorseHere() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        print("anchors via FilingRouter.tokenize: \(r.rate(.anchorsViaRouterTokenize))")
        #expect(r.rate(.anchorsViaRouterTokenize) < 0.70,
                "if the router's tokenizer now agrees, re-measure before unifying them")
        #expect(r.rate(.anchors) - r.rate(.anchorsViaRouterTokenize) > 0.25)
    }

    // MARK: - Axes

    @Test func theYearAxesAreExact() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.rate(.year) == 1.0, r.misses(.year))
        #expect(r.rate(.fiscalYear) == 1.0, r.misses(.fiscalYear))
    }

    @Test func theJurisdictionAxisIsExactGivenItsVocabulary() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.rate(.jurisdiction) == 1.0, r.misses(.jurisdiction))
    }

    @Test func thePersonAndLifecycleAxesAgree() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.rate(.person) >= 0.99, r.misses(.person))
        #expect(r.rate(.lifecycle) >= 0.99, r.misses(.lifecycle))
    }
}

/// The walk's give-up path, tested without a live tree.
///
/// **Ungated on purpose.** The suite above needs the real profile, the right machine and an awake
/// display, so on most runs it says nothing at all — and the stall handling it relies on would then
/// be exercised by nothing. `walk` is a plain function over a directory, so its deadline and its
/// short-circuit can be pinned anywhere, on any machine, in milliseconds.
@Suite struct FolderSurveyWalkBudgetTests {

    @Test func aWalkPastItsDeadlineGivesUpAndSaysSo() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var stalled = false
        let cut = FolderSurveyGroundTruth.walk(dir, deadline: .distantPast, stalled: &stalled,
                                               keepGoing: { true })
        #expect(stalled, "a walk past its deadline did not report giving up")
        #expect(cut.isEmpty)

        // The control, and the half that would go vacuous first: with time left it walks and does
        // NOT set the flag, so `stalled` is a measurement rather than a constant.
        var ok = false
        let full = FolderSurveyGroundTruth.walk(dir, deadline: .distantFuture, stalled: &ok,
                                                keepGoing: { true })
        #expect(!ok)
        #expect(full.count == 1, "the fixture tree was not walked at all")
        #expect(full.first?.children?.count == 1)
    }

    /// The display half of the give-up rule, driven directly rather than by putting the machine to
    /// sleep: a walk whose condition goes false stops and reports it, which is what turns a display
    /// that sleeps mid-run from an open-ended wait into a named failure.
    @Test func aWalkStopsWhenItsConditionGoesFalse() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var stalled = false
        let out = FolderSurveyGroundTruth.walk(dir, deadline: .distantFuture, stalled: &stalled,
                                               keepGoing: { false })
        #expect(stalled, "the walk kept going with its condition false")
        #expect(out.isEmpty)
    }

    /// Once it has given up it stays given up, so sibling subtrees are not walked one by one after
    /// the budget is spent — the short-circuit is what keeps a stalled walk from taking as long as
    /// an unbounded one.
    @Test func givingUpStopsTheRemainingSiblings() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walk-\(UUID().uuidString)")
        for name in ["a", "b", "c"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        var stalled = true                      // as if a deeper call had already given up
        let out = FolderSurveyGroundTruth.walk(dir, deadline: .distantFuture, stalled: &stalled,
                                               keepGoing: { true })
        #expect(out.isEmpty, "a walk that had already given up kept going")
        #expect(stalled)
    }
}

// MARK: - The comparison itself

/// Walks the real tree once, builds a profile from it, and compares field by field against the
/// hand-built one. Computed lazily and exactly once — the walk is the expensive part.
enum FolderSurveyGroundTruth {

    /// The jurisdiction vocabulary, **written here rather than read out of the profile**.
    ///
    /// The axis is 100% *given* its values and nothing in a folder name says which names are
    /// jurisdictions — `Singapore` is one and `Chase` is not. Deriving the list from the very
    /// entries being graded would make the test circular, so it is stated: this is what a user
    /// would declare for this tree, and the profile's own `axes.jurisdiction.values` names the
    /// first two of them.
    static let declaredJurisdictions: Set<String> = ["US", "IN", "Singapore"]

    enum Field: String, CaseIterable {
        case role, anchors, acceptsNewFiles, fileCount, subfolderCount
        case year, fiscalYear, jurisdiction, person, lifecycle
        case anchorsViaRouterTokenize
    }

    struct Report {
        /// Set when the walk hit ``walkBudget`` instead of finishing. Carried on the report so a
        /// stall reports as one named failure rather than as a scatter of agreement failures whose
        /// real cause is that the tree was never fully read.
        var walkStalled = false
        var shared = 0
        var builtOnly = 0
        var profileOnly = 0
        var matches: [Field: Int] = [:]
        var examples: [Field: [String]] = [:]
        var distinctRoles = 0
        var expectedAxisValues: [String: Int] = [:]
        var foldersWithAnchors = 0
        var refusals = 0
        var refusalsCaught = 0
        var falseRefusals = 0

        func rate(_ field: Field) -> Double {
            shared == 0 ? 0 : Double(matches[field] ?? 0) / Double(shared)
        }
        func expected(axis: String) -> Int { expectedAxisValues[axis] ?? 0 }
        func misses(_ field: Field) -> Comment {
            let sample = (examples[field] ?? []).prefix(6).joined(separator: "\n  ")
            return "\(field.rawValue) agreed on \(matches[field] ?? 0)/\(shared)\n  \(sample)"
        }
        var description: String {
            var out = "FolderSurveyBuilder vs the hand-built profile — \(shared) shared folders "
                + "(\(builtOnly) new in the tree, \(profileOnly) gone from it)\n"
            for field in Field.allCases {
                out += String(format: "  %-24s %.4f  (%d differ)\n",
                              (field.rawValue as NSString).utf8String!,
                              rate(field), shared - (matches[field] ?? 0))
            }
            return out
        }
    }

    /// Whether the main display is awake.
    ///
    /// The one measured cause of this suite stalling, so it gates the suite rather than being left
    /// to the budget: with the display off, an iCloud-backed walk makes no progress at all, and a
    /// budget can only turn that into a red two minutes later on every unattended run. An explicit
    /// skip naming the reason is the honest outcome — the suite is machine-pinned already, so it
    /// carries no CI verdict to lose.
    ///
    /// **Two limits worth knowing, and the first one bites more often than it looks.** It is a skip,
    /// so the only test that can say whether the survey rules still match the real tree may go a
    /// long time without running, and nothing reports that. This machine's display cycles off a
    /// lot — `pmset -g log` for a single working morning shows off at 09:06, on at 09:20, off at
    /// 09:30, on at 09:46, off at 09:57 — so "the display happened to be off" is an ordinary
    /// condition here, not an edge case, and a green package run is routinely a run where this
    /// suite said nothing at all. **After changing a rule, check deliberately that it ran**; the
    /// skip reason is printed, so the evidence is there if you look for it.
    ///
    /// Second, the query needs a window server: from an SSH session, or with no display attached,
    /// `CGMainDisplayID()` gives the null display and this reads AWAKE, so the gate does not protect
    /// a headless run. Neither limit is a reason to drop it — it turns the one observed failure mode
    /// from an 8,888s hang into an instant, labelled skip — but the coverage this costs is real and
    /// is paid on ordinary days.
    static var displayIsAwake: Bool { CGDisplayIsAsleep(CGMainDisplayID()) == 0 }

    /// One line saying whether the gated suite above ran, and if not, which gate closed it.
    ///
    /// Pure and taking both gates as arguments so `FolderSurveyGroundTruthGateTests` can pin it for
    /// the combinations this machine does not happen to be in — a report that only ever reports the
    /// current state is a report nothing can check. Gates are named in the suite's own order, so the
    /// line always blames the one that actually stopped it.
    static func gateLine(excluded: Bool, liveProfile: Bool, displayAwake: Bool) -> String {
        // **Named first because it is the outermost gate**, and because it is the only one of the
        // three that is true on CI every single time. `.machinePinned(.liveProfile)` is a
        // `.disabled(if:)`, so when the reason is excluded the suite below produces no results at
        // all — while the two gates under this one still read *true* on the self-hosted runner (same
        // Mac, same user, profile right there). Without this the line said RAN on a run where the
        // ground truth had not been near a real tree.
        guard !excluded else {
            return "SKIPPED — liveProfile is in SYNCCLOUD_SKIP_MACHINE_PINNED, so the suite is disabled here; the survey rules were not checked against a real tree"
        }
        guard liveProfile else {
            return "SKIPPED — no live folder profile on this machine; the survey rules were not checked against a real tree"
        }
        guard displayAwake else {
            return "SKIPPED — the display is asleep; an iCloud walk makes no progress, so the survey rules were not checked against a real tree"
        }
        return "RAN — the survey rules were checked against the live tree"
    }

    static let report: Report? = {
        guard let expected = LiveProfile.profile else { return nil }
        let root = (expected.root as NSString).expandingTildeInPath
        guard let directory = FilingProfileStore.defaultDirectory() else { return nil }
        let registry = FilingProfileStore.personRegistry(id: expected.profileId, profile: expected,
                                                         in: directory)
        var stalled = false
        let tree = walk(URL(fileURLWithPath: root),
                        deadline: Date().addingTimeInterval(walkBudget), stalled: &stalled)
        let built = FolderSurveyBuilder.build(tree: tree, root: expected.root,
                                              profileId: expected.profileId, registry: registry,
                                              jurisdictionValues: declaredJurisdictions)
        var contents: [String: (components: [String], files: [String])] = [:]
        flatten(tree, at: FolderSurveyBuilder.rootPath, components: [], into: &contents)

        var r = Report()
        r.walkStalled = stalled
        r.builtOnly = built.folders.keys.filter { expected.folders[$0] == nil }.count
        r.profileOnly = expected.folders.keys.filter { built.folders[$0] == nil }.count

        var roles = Set<FolderRole>()
        for (path, want) in expected.folders.sorted(by: { $0.key < $1.key }) {
            if let role = want.role { roles.insert(role) }
            for (axis, _) in want.axes { r.expectedAxisValues[axis, default: 0] += 1 }
            if !want.anchors.isEmpty { r.foldersWithAnchors += 1 }
            let refuses = want.acceptsNewFiles == false || want.role == .inbox
            if refuses && FolderProfile.isInboxPath(path) { r.refusals += 1 }

            guard let got = built.folders[path] else { continue }
            r.shared += 1
            if refuses && FolderProfile.isInboxPath(path), got.acceptsNewFiles == false {
                r.refusalsCaught += 1
            }
            if got.acceptsNewFiles == false && want.acceptsNewFiles != false && want.role != .inbox {
                r.falseRefusals += 1
            }
            func check(_ field: Field, _ agrees: Bool, _ detail: @autoclosure () -> String) {
                if agrees {
                    r.matches[field, default: 0] += 1
                } else if (r.examples[field]?.count ?? 0) < 6 {
                    r.examples[field, default: []].append("\(path) — \(detail())")
                }
            }
            check(.role, got.role == want.role, "built \(got.role.map(\.rawValue) ?? "nil"), "
                  + "profile \(want.role.map(\.rawValue) ?? "nil")")
            check(.anchors, got.anchors == want.anchors, "built \(got.anchors), profile \(want.anchors)")
            check(.acceptsNewFiles, got.acceptsNewFiles == want.acceptsNewFiles, "")
            check(.fileCount, got.fileCount == want.fileCount,
                  "built \(got.fileCount), profile \(want.fileCount)")
            check(.subfolderCount, got.subfolderCount == want.subfolderCount,
                  "built \(got.subfolderCount), profile \(want.subfolderCount)")
            for axis: Field in [.year, .fiscalYear, .jurisdiction, .person, .lifecycle] {
                let a = got.axes[axis.rawValue], b = want.axes[axis.rawValue]
                check(axis, a == b, "built \(a ?? "nil"), profile \(b ?? "nil")")
            }
            if let raw = contents[path] {
                let viaRouter = FolderSurveyBuilder.anchors(components: raw.components,
                                                            fileNames: raw.files,
                                                            tokenizer: FilingRouter.tokenize)
                check(.anchorsViaRouterTokenize, viaRouter == want.anchors,
                      "built \(viaRouter), profile \(want.anchors)")
            }
        }
        r.distinctRoles = roles.count
        return r
    }()

    /// The raw material each folder's anchors were mined from — its path components and the
    /// filenames the builder kept — so the anchor pipeline can be re-run with a different
    /// tokenizer over exactly the same input. Mirrors the builder's own descent, and reuses its
    /// ``FolderSurveyBuilder/partition(_:)`` so the two cannot disagree about what a file is.
    static func flatten(_ children: [FileNode], at path: String, components: [String],
                        into map: inout [String: (components: [String], files: [String])]) {
        let (files, folders) = FolderSurveyBuilder.partition(children)
        map[path] = (components, files)
        for folder in folders where folder.isUnexplored != true {
            let child = components + [folder.name]
            flatten(folder.children ?? [], at: child.joined(separator: "/"), components: child,
                    into: &map)
        }
    }

    /// The wall-clock budget for the whole live walk.
    ///
    /// **Not a performance bar, and not the thing that handles the stall this was written for.** The
    /// budget is checked between `contentsOfDirectory` calls, so it bounds a walk that is *slow* —
    /// it cannot interrupt one blocked inside a single call, which is what the observed stall is (no
    /// progress at all, main thread idle at 0% CPU). ``displayIsAwake`` is what covers that mode;
    /// this covers the glacial one, and means a walk that degrades rather than stops ends in a named
    /// failure instead of an open-ended wait. A warm
    /// attended walk of this tree measures ~84ms and a cold one ~1.05s, and even under Rosetta it
    /// measured 10.8s, so two minutes is far above anything a working walk does. What it is sized
    /// against is the stall: an iCloud-backed `~/Documents` makes no progress while the display is
    /// asleep — four matched cases on 2026-08-13, one of which ran **8,888s** — and this suite walks
    /// the real tree from a `static let`, so every test in it blocks on that. `docs/flaky-tests.md`
    /// mechanism 8 is the shape being avoided: a run with no verdict is worse than a red one.
    ///
    /// A `.timeLimit` trait could not have covered this: the block is a non-cancellable
    /// `contentsOfDirectory` syscall inside a lazy static, not a task the runner can cancel. For the
    /// same reason this budget cannot rescue a walk wedged *inside* one such call.
    static let walkBudget: TimeInterval = 120

    /// A depth-first walk producing the nodes directly inside `url`. Symlinks are marked and never
    /// followed — a cycle would hang the suite, and `docs/flaky-tests.md` has enough entries about
    /// tests that hang instead of failing.
    ///
    /// Gives up at `deadline` — or as soon as the display goes to sleep — setting `stalled` and
    /// returning what it has. The partial tree is
    /// deliberately still returned rather than discarded: the agreement tests then fail on a tree
    /// too small to match, which is a named failure, and `theLiveWalkFinishedWithinItsBudget` says
    /// in one line which of those failures is really this.
    static func walk(_ url: URL, deadline: Date, stalled: inout Bool,
                     keepGoing: () -> Bool = { displayIsAwake }) -> [FileNode] {
        // **`keepGoing` re-checks the display, and it is a parameter rather than a direct call for
        // the usual reason**: a walk that consults global state is a walk no test can drive, and
        // this one would refuse to run at all on a machine whose display happens to be asleep —
        // which is most of them, most of the time.
        //
        // The check itself matters because the suite's gate is evaluated once, before any of this
        // runs: a run that starts with the display awake and meets a display that sleeps thirty
        // seconds later gets nothing from it. Between directory reads is the last moment this code
        // is still in control — once inside a `contentsOfDirectory` that will not return, nothing
        // here runs again.
        walkChildren(url, deadline: deadline, stalled: &stalled, keepGoing: keepGoing) ?? []
    }

    /// The walk, with **"could not read this directory" kept distinct from "this directory is
    /// empty"** — `nil` for the first, `[]` for the second.
    ///
    /// This walker is the *reference* side of every agreement number in this suite, so a place where
    /// it disagrees with the production walker is a place the comparison is measuring the fixture
    /// rather than the rules. It used to answer `[]` for both cases, while the production walk
    /// reports an unreadable directory as `isUnexplored: true` — so a folder the test process cannot
    /// open counted as an explored, empty folder that production says nothing about. Under floors
    /// expressed as *agreement ≥ 0.99*, a handful of those is absorbed rather than surfaced, which is
    /// the shape of a masked miss: the number stays green and the thing it certifies is not what you
    /// think.
    ///
    /// A stall still answers `[]` rather than `nil`, deliberately. Stalling is already reported
    /// through `stalled` and has a non-vacuity test of its own, so it is not a silent condition; an
    /// unreadable directory had nothing.
    static func walkChildren(_ url: URL, deadline: Date, stalled: inout Bool,
                             keepGoing: () -> Bool = { displayIsAwake }) -> [FileNode]? {
        if stalled || Date() >= deadline || !keepGoing() { stalled = true; return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys) else { return nil }
        var out: [FileNode] = []
        for child in entries {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink ?? false
            let isDirectory = (values?.isDirectory ?? false) && !isLink
            let below = isDirectory
                ? walkChildren(child, deadline: deadline, stalled: &stalled, keepGoing: keepGoing)
                : nil
            out.append(FileNode(id: child.path, name: child.lastPathComponent,
                                isDirectory: isDirectory,
                                children: isDirectory ? (below ?? []) : nil,
                                isUnexplored: isDirectory && below == nil ? true : nil,
                                isSymbolicLink: isLink ? true : nil))
        }
        return out
    }
}
