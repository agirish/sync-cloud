import Testing
import Foundation
import CoreGraphics
@testable import Sync

/// Always runs, so a skipped ground truth shows in the run instead of being inferred from an
/// absence. The gated suite below produces no results at all when a gate is closed, and on this
/// machine the display gate closes on ordinary days. The first test pins the report's logic across
/// every gate combination, so it can't say "ran" for a closed gate; the second emits the real line
/// and checks it against the gates it read.
@Suite struct FolderSurveyGroundTruthGateTests {

    @Test func theGateLineNamesWhicheverGateIsClosed() {
        typealias G = FolderSurveyGroundTruth
        func gateLine(liveProfile: Bool, displayAwake: Bool) -> String {
            G.gateLine(excluded: false, liveProfile: liveProfile, displayAwake: displayAwake)
        }
        // The exclusion outranks both, including the combination that would otherwise say RAN,
        // which is the only one CI ever takes.
        for (profile, awake) in [(true, true), (true, false), (false, true), (false, false)] {
            let line = G.gateLine(excluded: true, liveProfile: profile, displayAwake: awake)
            #expect(line.hasPrefix("SKIPPED"), "an excluded reason reported \(line)")
            #expect(line.contains("SYNCCLOUD_SKIP_MACHINE_PINNED"),
                    "an excluded reason must name the variable that excluded it: \(line)")
        }
        #expect(gateLine(liveProfile: true, displayAwake: true).hasPrefix("RAN"))
        // The profile is reported first because it is the suite's first gate: with no profile the
        // display isn't why the suite said nothing, and naming it would send a reader the wrong way.
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
        // stdout, because a CI step log keeps it. `Logger.shared.entries` is capped and shared by
        // every suite in the package (`docs/flaky-tests.md`, "A log assertion reading a window that
        // has already rolled").
        print("[ground-truth] \(line)")
        #expect(line.hasPrefix("RAN") == (!excluded && liveProfile && awake),
                "the gate report says \(line) while the gates read excluded=\(excluded) liveProfile=\(liveProfile) displayAwake=\(awake)")
    }

    /// An unreadable directory is `isUnexplored`, not an explored empty one, matching the
    /// production walk. Otherwise a directory the test can't open counts as genuinely empty, and
    /// floors of agreement ≥ 0.99 absorb a few of those instead of failing. Lives in the ungated
    /// suite so the gates that skip the ground truth don't skip this too; a temporary tree answers
    /// it. Both directions, since a walker marking every directory unexplored passes the first.
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

/// ``FolderSurveyBuilder`` re-derived against the hand-built folder profile and the real tree it
/// describes: the only test that can say whether the rules are right, since a synthetic tree can
/// only replay them. The floors are the measured agreement minus a small margin, below 100% because
/// the tree drifts (only shared paths are compared) and some refusals (`outbound-pack`) are
/// judgement no walk can re-derive. Machine-pinned, since the walk under Rosetta starves the
/// timing-sensitive suites beside it on the self-hosted runner (``MachinePinnedReason/liveProfile``),
/// and gated on the display, since a sleeping display stalls the one iCloud walk every test blocks
/// on (`docs/flaky-tests.md`, "The wait that hangs instead of failing").
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
        #expect(r.refusals >= 39, "the profile records at least 39 inbox folders that refuse files")
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

    /// Agreement is measured over the refusals, not the whole field: nearly every profile entry
    /// records nothing there, so a builder that always answered nil would score about 98.5% on a
    /// naive count. What matters is that every inbox is refused and nothing else is. Over the shared
    /// folders only, like every other agreement here: an inbox the profile records but the tree no
    /// longer has can't be caught, because the builder never sees it.
    @Test func everyInboxIsRefusedAndNothingElseIs() throws {
        let r = try #require(FolderSurveyGroundTruth.report)
        #expect(r.sharedRefusals > 0, "no inbox in both the profile and the tree — the check is vacuous")
        #expect(r.refusalsCaught == r.sharedRefusals, "an inbox the builder let through")
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

/// The walk's give-up path, tested without a live tree. Ungated on purpose: the suite above
/// usually skips, and the stall handling it relies on would then be exercised by nothing. `walk` is
/// a plain function over a directory, so its deadline and short-circuit can be pinned anywhere.
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

        // The control: with time left it walks and does not set the flag, so `stalled` is a
        // measurement rather than a constant.
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

    /// The jurisdiction vocabulary, written here rather than read out of the profile. Nothing in a
    /// folder name says which names are jurisdictions (`Singapore` is one, `Chase` is not), and
    /// deriving the list from the entries being graded would make the test circular. This is what
    /// a user would declare for this tree.
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
        /// Inbox refusals the profile records, whether or not the tree still has the folder — the
        /// size of the profile, for the floor in ``theComparisonCoversTheWholeRealProfile``.
        var refusals = 0
        /// The subset of ``refusals`` whose folder the walk also found: the only ones the builder
        /// could have caught, so the denominator for ``refusalsCaught``.
        var sharedRefusals = 0
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
            // "The active profile on disk", not "the hand-built profile": `LiveProfile` loads
            // whatever `FilingProfileStore.activeProfileId` names, which is a derived profile on any
            // machine that has applied a reorganisation.
            var out = "FolderSurveyBuilder vs the active profile on disk — \(shared) shared folders "
                + "(\(builtOnly) new in the tree, \(profileOnly) gone from it)\n"
            for field in Field.allCases {
                out += String(format: "  %-24s %.4f  (%d differ)\n",
                              (field.rawValue as NSString).utf8String!,
                              rate(field), shared - (matches[field] ?? 0))
            }
            return out
        }
    }

    /// Whether the main display is awake. With the display off an iCloud-backed walk makes no
    /// progress at all, so this gates the suite with a named skip rather than leaving a budget to
    /// turn it into a red minutes later.
    ///
    /// Two limits. It is a skip, and this display sleeps often, so a green package run is often one
    /// where this suite said nothing: after changing a rule, check that it ran (the skip reason is
    /// printed). And it needs a window server: over SSH or with no display, `CGMainDisplayID()`
    /// gives the null display and this reads awake, so it doesn't protect a headless run.
    static var displayIsAwake: Bool { CGDisplayIsAsleep(CGMainDisplayID()) == 0 }

    /// One line saying whether the gated suite above ran, and if not, which gate closed it. Pure,
    /// so `FolderSurveyGroundTruthGateTests` can pin it for combinations this machine isn't in.
    /// Gates are checked in the suite's own order, so the line blames the one that stopped it.
    static func gateLine(excluded: Bool, liveProfile: Bool, displayAwake: Bool) -> String {
        // First because it is the outermost gate, and the one closed on every CI run.
        // `.machinePinned(.liveProfile)` disables the suite while the two gates below still read
        // true on the self-hosted runner, so without this the line would say RAN.
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

    /// The real tree, walked once for every suite that needs it
    /// (`JurisdictionConfidenceGroundTruthTests` too), since each walk of an iCloud-backed
    /// `~/Documents` is this file's main cost and its main exposure to the display sleeping.
    static let liveWalk: (tree: [FileNode], stalled: Bool) = {
        guard let expected = LiveProfile.profile else { return ([], false) }
        let root = (expected.root as NSString).expandingTildeInPath
        var stalled = false
        let tree = walk(URL(fileURLWithPath: root),
                        deadline: Date().addingTimeInterval(walkBudget), stalled: &stalled)
        return (tree, stalled)
    }()

    static let report: Report? = {
        guard let expected = LiveProfile.profile else { return nil }
        guard let directory = FilingProfileStore.defaultDirectory() else { return nil }
        let registry = FilingProfileStore.personRegistry(id: expected.profileId, profile: expected,
                                                         in: directory)
        let (tree, stalled) = liveWalk
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
            if refuses && FolderProfile.isInboxPath(path) {
                r.sharedRefusals += 1
                if got.acceptsNewFiles == false { r.refusalsCaught += 1 }
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
                // The person axis is compared the way the app resolves it, not by spelling. Every
                // consumer of `axes["person"]` reads it through
                // `PersonRegistry.person(forAxisValue:)`, which lowercases, so `Daughter` and
                // `daughter` are the same person to the app. The spelling depends on where the
                // registry came from (display names or token ids), and this suite checks the rules.
                //
                // Not `.lowercased()`, which would pass two unrelated unresolvable strings: resolved
                // identity, and raw equality when neither side resolves, so a wrong attribution or a
                // nil on one side still fails.
                let agrees: Bool
                if axis == .person {
                    let ra = a.flatMap { registry.person(forAxisValue: $0) }
                    let rb = b.flatMap { registry.person(forAxisValue: $0) }
                    agrees = (ra != nil || rb != nil) ? ra == rb : a == b
                } else {
                    agrees = a == b
                }
                check(axis, agrees, "built \(a ?? "nil"), profile \(b ?? "nil")")
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

    /// The wall-clock budget for the whole live walk. Not a performance bar: a working walk of this
    /// tree takes about a second cold, and ~11s under Rosetta. It is checked between
    /// `contentsOfDirectory` calls, so it ends a walk that degrades in a named failure instead of
    /// an open-ended wait (`docs/flaky-tests.md`, "The wait that hangs instead of failing"). It
    /// can't interrupt a walk blocked inside one call, which is what a sleeping display causes;
    /// ``displayIsAwake`` covers that. Nor could a `.timeLimit` trait: the block is a
    /// non-cancellable syscall inside a lazy static.
    static let walkBudget: TimeInterval = 120

    /// A depth-first walk producing the nodes directly inside `url`. Symlinks are marked and never
    /// followed, since a cycle would hang the suite. Gives up at `deadline`, or as soon as the
    /// display sleeps, setting `stalled` and returning what it has, so the agreement tests fail on
    /// a short tree and `theLiveWalkFinishedWithinItsBudget` names the real cause.
    static func walk(_ url: URL, deadline: Date, stalled: inout Bool,
                     keepGoing: () -> Bool = { displayIsAwake }) -> [FileNode] {
        // `keepGoing` is a parameter so tests can drive the walk on a machine whose display is
        // asleep. It re-checks the display between directory reads because the suite's gate is
        // read once, before the walk, and a display can sleep mid-run; once inside a
        // `contentsOfDirectory` that won't return, nothing here runs again.
        walkChildren(url, deadline: deadline, stalled: &stalled, keepGoing: keepGoing) ?? []
    }

    /// The walk, with "could not read this directory" (`nil`) kept distinct from "this directory is
    /// empty" (`[]`). This is the reference side of every agreement number, so it must match the
    /// production walk, which reports an unreadable directory as `isUnexplored: true`. A stall
    /// still answers `[]`, since `stalled` already reports it.
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
