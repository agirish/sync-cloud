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
        let why = "the live walk gave up after \(Int(FolderSurveyGroundTruth.walkBudget))s — it is stalling rather than running slowly, and every other failure in this suite is downstream of that"
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
    static var displayIsAwake: Bool { CGDisplayIsAsleep(CGMainDisplayID()) == 0 }

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
    /// **Not a performance bar — the thing that makes this suite fail instead of hang.** A warm
    /// attended walk of this tree measures ~84ms and a cold one ~1.05s, and even under Rosetta it
    /// measured 10.8s, so two minutes is far above anything a working walk does. What it is sized
    /// against is the stall: an iCloud-backed `~/Documents` makes no progress while the display is
    /// asleep — four matched cases on 2026-08-13, one of which ran **8,888s** — and this suite walks
    /// the real tree from a `static let`, so every test in it blocks on that. `docs/flaky-tests.md`
    /// mechanism 8 is the shape being avoided: a run with no verdict is worse than a red one.
    ///
    /// A `.timeLimit` trait could not have covered this: the block is a non-cancellable
    /// `contentsOfDirectory` syscall inside a lazy static, not a task the runner can cancel. For the
    /// same reason this budget cannot rescue a walk wedged *inside* one such call — it bounds the
    /// case where progress is merely glacial, and ``displayIsAwake`` gates the case where it stops
    /// altogether.
    static let walkBudget: TimeInterval = 120

    /// A depth-first walk producing the nodes directly inside `url`. Symlinks are marked and never
    /// followed — a cycle would hang the suite, and `docs/flaky-tests.md` has enough entries about
    /// tests that hang instead of failing.
    ///
    /// Gives up at `deadline`, setting `stalled` and returning what it has. The partial tree is
    /// deliberately still returned rather than discarded: the agreement tests then fail on a tree
    /// too small to match, which is a named failure, and `theLiveWalkFinishedWithinItsBudget` says
    /// in one line which of those failures is really this.
    static func walk(_ url: URL, deadline: Date, stalled: inout Bool) -> [FileNode] {
        if stalled || Date() >= deadline { stalled = true; return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys) else { return [] }
        var out: [FileNode] = []
        for child in entries {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink ?? false
            let isDirectory = (values?.isDirectory ?? false) && !isLink
            out.append(FileNode(id: child.path, name: child.lastPathComponent,
                                isDirectory: isDirectory,
                                children: isDirectory
                                    ? walk(child, deadline: deadline, stalled: &stalled) : nil,
                                isSymbolicLink: isLink ? true : nil))
        }
        return out
    }
}
