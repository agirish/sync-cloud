import Testing
import Foundation
@testable import Sync

/// The one accessor rule: suppression is honoured at `visibleStructureFindings`, which every
/// surface reads, so the lens, the overview and the rail badge cannot disagree about what
/// "never suggest this again" meant.
/// Profile `t` at `/r`: each of `families` a firing backlog family (two claimed years and a loose
/// `2025`), plus `extra` folders as path → (files, subfolders).
private func backlogProfile(families: [String] = ["Dental"],
                            extra: [String: (Int, Int)] = [:]) -> FolderProfile {
    var shape: [String: (Int, Int)] = extra
    for family in families {
        shape[family] = (0, 3)
        for year in ["2023", "2024"] {
            shape["\(family)/\(year)"] = (0, 1)
            shape["\(family)/\(year)/Claims"] = (2, 0)
        }
        shape["\(family)/2025"] = (2, 0)
    }
    let folders = shape.reduce(into: [String: FolderProfileEntry]()) { folders, item in
        folders[item.key] = FolderProfileEntry(path: item.key, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: nil, fileCount: item.value.0,
                                               subfolderCount: item.value.1, axes: [:])
    }
    return FolderProfile(profileId: "t", root: "/r", folders: folders, personTokens: [])
}

/// A manager over `backlogProfile(families:extra:)`, with its store in a fresh directory.
@MainActor
private func dentalManager(_ prefix: String, families: [String] = ["Dental"],
                           extra: [String: (Int, Int)] = [:]) throws -> (manager: FileSyncManager, dir: URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"), withIntermediateDirectories: true)
    let manager = FileSyncManager()
    manager.filingFolderProfile = backlogProfile(families: families, extra: extra)
    manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
    return (manager, dir)
}

/// An undo manager on `manager` with `finding` hidden in one closed group, as Never suggest does.
@MainActor
private func hideWithUndo(_ manager: FileSyncManager, _ finding: StructureFinding) -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    manager.undoManager = undo
    undo.beginUndoGrouping()
    manager.suppressStructureFinding(finding)
    undo.endUndoGrouping()
    return undo
}

/// A same-text group of `name` in each of `folders` under `root`: the duplicate scan's half of a
/// duplicated-taxonomy finding.
private func papersGroup(_ name: String, in folders: [String], under root: String) -> DuplicateGroup {
    .stub(folders.map { .stub("\(root)/\($0)/\(name)", keeper: false, size: 10, depth: 3) },
          matchType: .sameText, name: name, isDirectory: false, reclaimable: 0)
}

@MainActor
@Suite struct RestructureVisibilityTests {

    private func makeManager() throws -> (manager: FileSyncManager, dir: URL) {
        try dentalManager("visibility")
    }

    /// Never suggest this again can be taken back: it registers one ⌘Z step with an undoable
    /// banner, and Show them again brings back everything hidden.
    @Test func neverSuggestCanBeUndoneAndShownAgain() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })

        // A key for a folder that no longer produces a finding is not counted as hidden.
        let stale = RestructureKey(kind: .backlog, path: "Gone/Folder")
        manager.restructureStore?.suppress(stale)
        #expect(manager.hiddenStructureFindings(in: nil).isEmpty)

        let undo = hideWithUndo(manager, finding)
        #expect(!manager.visibleStructureFindings.contains { $0.id == finding.id })
        #expect(manager.hiddenStructureFindings(in: nil).map(\.id) == [finding.id])
        #expect(manager.banner?.isUndoable == true, "the banner offered no Undo")

        undo.undo()
        #expect(manager.banner?.isUndoable != true,
                "Edit ▸ Undo left the “Hidden [Undo]” banner up; its Undo now pops the redo")
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id },
                "undo left the finding hidden")

        undo.redo()
        #expect(!manager.visibleStructureFindings.contains { $0.id == finding.id })

        #expect(manager.showHiddenStructureFindings(in: nil) == 1)
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id })
        #expect(manager.restructureStore?.suppressed == [stale],
                "Show them again cleared a key it never counted")
        #expect(manager.banner?.message == "1 hidden finding is back.")
    }

    /// Under a scoped list, Show them again counts and brings back only the hidden findings the
    /// scoped lens would show (inside the scope or about an ancestor of it), and leaves the rest
    /// hidden.
    @Test func showingHiddenFindingsAgainStaysInTheLensScope() throws {
        // A second family, outside the scope below.
        let (manager, dir) = try dentalManager("visibility", families: ["Dental", "Vision"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let dental = try #require(manager.structureFindings.first {
            $0.kind == .backlog && $0.subject.hasPrefix("Dental")
        })
        let vision = try #require(manager.structureFindings.first {
            $0.kind == .backlog && $0.subject.hasPrefix("Vision")
        })
        manager.restructureStore?.suppress(RestructureKey(dental))
        manager.restructureStore?.suppress(RestructureKey(vision))
        let scope = try #require(OrganizeScope(path: "/r/Dental", providerRoot: "/r"))

        #expect(manager.hiddenStructureFindings(in: scope).map(\.id) == [dental.id],
                "a finding outside the scope was counted under the scoped list")
        #expect(manager.hiddenStructureFindings(in: nil).count == 2)

        #expect(manager.showHiddenStructureFindings(in: scope) == 1)
        #expect(manager.restructureStore?.isSuppressed(RestructureKey(dental)) == false)
        #expect(manager.restructureStore?.isSuppressed(RestructureKey(vision)) == true,
                "Show them again brought back a finding outside the scope")
    }

    /// A hidden duplicated-taxonomy finding can be shown again. It comes from the duplicate scan,
    /// not the survey's report, so a hidden set that read the report alone would never count or
    /// bring it back, and nothing else lists it.
    @Test func aHiddenDuplicatedTaxonomyFindingCanBeShownAgain() throws {
        let (manager, dir) = try dentalManager(
            "visibility", extra: ["Papers": (0, 2), "Papers/One": (4, 0), "Papers/Two": (4, 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.duplicateGroups = ["a.pdf", "b.pdf", "c.pdf"].map {
            papersGroup($0, in: ["Papers/One", "Papers/Two"], under: "/r")
        }
        manager.duplicateScanRoot = "/r"
        let taxonomy = try #require(manager.visibleStructureFindings.first {
            $0.kind == .duplicatedTaxonomy
        })

        manager.suppressStructureFinding(taxonomy)
        #expect(!manager.visibleStructureFindings.contains { $0.id == taxonomy.id },
                "premise: the finding is hidden")
        #expect(manager.hiddenStructureFindings(in: nil).map(\.id) == [taxonomy.id],
                "a hidden §5.9 finding is not counted by Show them again")

        #expect(manager.showHiddenStructureFindings(in: nil) == 1)
        #expect(manager.visibleStructureFindings.contains { $0.id == taxonomy.id },
                "Show them again left the §5.9 finding hidden")
    }

    /// ⌘Z of Never suggest reaches the store that replaced the one it hid in. A landing or survey
    /// refresh opens the new profile's store with the hidden set carried across, so clearing the
    /// old store alone would leave the finding hidden in the one the lens reads.
    @Test func undoingNeverSuggestReachesTheStoreThatReplacedTheOne() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })

        let undo = hideWithUndo(manager, finding)

        // The swap: a new profile's store, carrying the hidden key the way the re-derive does.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t2"),
                                                withIntermediateDirectories: true)
        let original = try #require(manager.restructureStore)
        let swapped = RestructureStore(directory: dir, profileId: "t2")
        swapped.suppress(RestructureKey(finding))
        swapped.adoptLineage(from: original, renames: [])
        manager.restructureStore = swapped
        #expect(!manager.visibleStructureFindings.contains { $0.id == finding.id },
                "premise: the carried key hides the finding in the new store")

        undo.undo()
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id },
                "undo cleared the old store and left the finding hidden in the new one")
        #expect(!swapped.isSuppressed(RestructureKey(finding)))
        // From disk: the swapped-out object is not what the undo writes through.
        #expect(!RestructureStore(directory: dir, profileId: "t").isSuppressed(RestructureKey(finding)))
    }

    /// ⌘Z after a provider switch leaves another profile's store alone: there the same kind and
    /// path is a different folder's finding, hidden on its own. Only a store carried on from the
    /// one it was hidden in is reached; a switch carries nothing.
    @Test func undoingNeverSuggestLeavesAnotherProfilesStoreAlone() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        let original = try #require(manager.restructureStore)

        let undo = hideWithUndo(manager, finding)

        // The switch: another provider's profile, which hid the same kind and path itself.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("other"),
                                                withIntermediateDirectories: true)
        let other = RestructureStore(directory: dir, profileId: "other")
        other.suppress(RestructureKey(finding))
        manager.restructureStore = other

        undo.undo()
        #expect(other.isSuppressed(RestructureKey(finding)),
                "undo un-hid a finding another profile had hidden on its own")
        #expect(!RestructureStore(directory: dir, profileId: original.profileId)
                    .isSuppressed(RestructureKey(finding)),
                "undo did not clear the key in the store it was hidden in")
    }

    /// ⌘Z after a renaming landing follows the landing's renames to the re-keyed entry in the new
    /// store, where the old spelling names nothing.
    @Test func undoingNeverSuggestFollowsTheLandingsRenames() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        let original = try #require(manager.restructureStore)
        let key = RestructureKey(finding)
        #expect(key.path.hasPrefix("Dental"), "premise: the rename below moves this key")

        let undo = hideWithUndo(manager, finding)

        // The landing's swap: the hidden set carried across and re-keyed through the rename.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t2"),
                                                withIntermediateDirectories: true)
        let renames = [(from: "Dental", to: "Health/Dental")]
        let landed = RestructureStore(directory: dir, profileId: "t2")
        landed.suppress(key)
        landed.rekey(renames: renames)
        landed.adoptLineage(from: original, renames: renames)
        let moved = try #require(landed.suppressed.first)
        #expect(moved != key && moved.path.hasPrefix("Health/Dental"),
                "premise: the landing re-keyed the hidden entry")
        manager.restructureStore = landed

        undo.undo()
        #expect(landed.suppressed.isEmpty,
                "undo cleared the old spelling and left the re-keyed entry hidden")
        #expect(!RestructureStore(directory: dir, profileId: "t").isSuppressed(key))
    }

    /// A store reopened on the same file — the same profile loaded again — is the one the undo
    /// reaches, and the stale captured object writes nothing over it.
    @Test func undoingNeverSuggestReachesTheSameProfileReopened() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        let unrelated = RestructureKey(kind: .backlog, path: "Elsewhere/Folder")

        let undo = hideWithUndo(manager, finding)
        let reopened = RestructureStore(directory: dir, profileId: "t")
        #expect(reopened.isSuppressed(RestructureKey(finding)), "premise: the same file")
        reopened.suppress(unrelated)
        manager.restructureStore = reopened

        undo.undo()
        #expect(!reopened.isSuppressed(RestructureKey(finding)))
        let onDisk = RestructureStore(directory: dir, profileId: "t")
        #expect(onDisk.isSuppressed(unrelated),
                "the stale captured store wrote its old state over the reopened one")
        #expect(!onDisk.isSuppressed(RestructureKey(finding)))
    }

    @Test func withNoStoreTheVisibleSetIsTheWholeReport() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.restructureStore = nil
        #expect(manager.visibleStructureFindings == manager.structureFindings)
    }
}

/// The trend stamp reads the survey's own counts. The store dedupes and the chart draws; this is
/// the half in between: what goes into a point.
@MainActor
@Suite struct RestructureTrendStampTests {

    private func makeManager() throws -> (manager: FileSyncManager, dir: URL) {
        let (manager, dir) = try dentalManager("trend-stamp")
        manager.filingProfileDirectoryId = "t"
        return (manager, dir)
    }

    /// The point carries the detectors' own per-kind counts, summing to what the lens shows.
    @Test func aStampCountsTheSurveysFindingsByKind() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = manager.structureFindings.count
        #expect(expected > 0, "a positive control: this profile fires")

        manager.stampStructureTrend()

        let point = try #require(manager.restructureStore?.trend.last)
        #expect(point.total == expected)
        #expect(point.profileId == "t")
        #expect(!point.landing, "an ordinary survey is not a landing")
        for (kind, count) in point.countsByKind {
            #expect(manager.structureFindings.filter { $0.kind.rawValue == kind }.count == count,
                    "the per-kind counts are the detectors\u{2019}, one for one")
        }
    }

    /// Suppression does not move the line: a trend that fell when the user hid a card would answer
    /// "is the tree getting better?" with "did you look away?".
    @Test func aSuppressedFindingStillCounts() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first)
        let expected = manager.structureFindings.count

        manager.restructureStore?.suppress(RestructureKey(finding))
        #expect(manager.visibleStructureFindings.count < expected,
                "a positive control: the suppression took")
        manager.stampStructureTrend()

        #expect(manager.restructureStore?.trend.last?.total == expected,
                "the trend counts what the detectors found, not what is on screen")
    }

    /// A profile already in the trend is answered from the trend alone. Reading the findings runs
    /// the whole detector sweep (about 325 ms on a 3,000-folder profile), and the launch call site
    /// runs before the window appears. A second stamp adds no point and leaves the first as it
    /// was; only a landing re-stamps.
    @Test func aProfileAlreadyStampedIsAnsweredWithoutCountingAgain() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.stampStructureTrend()
        let first = try #require(manager.restructureStore?.trend.last)
        #expect(first.total > 0)

        // Same profile id, second call: no new point, and the existing one is untouched.
        manager.stampStructureTrend()
        #expect(manager.restructureStore?.trend.count == 1)
        #expect(manager.restructureStore?.trend.last?.total == first.total)

        // A LANDING is the exemption — it re-stamps to record the cause.
        manager.stampStructureTrend(landing: true)
        #expect(manager.restructureStore?.trend.count == 1)
        #expect(manager.restructureStore?.trend.last?.landing == true)
    }

    /// With no profile there is no survey to count, and a zero point would read as a clean tree.
    @Test func nothingIsStampedWithoutAProfile() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.filingFolderProfile = nil
        manager.stampStructureTrend()
        #expect(manager.restructureStore?.trend.isEmpty == true)
    }
}

/// Scope relation reads the finding's subject: a backlog finding about `Health/Dental/2025` under
/// a scope pointed exactly there is work inside the scope, not an ancestor note about
/// `Health/Dental`.
@Suite struct StructureFindingScopeRelationTests {

    @Test func aScopeAtTheSubjectSeesTheFindingInside() throws {
        let finding = StructureFinding(kind: .backlog, family: "Health/Dental",
                                       subject: "Health/Dental/2025",
                                       detail: .backlog(scaffold: [], looseFiles: 2))
        let scope = try #require(OrganizeScope(path: "/r/Health/Dental/2025",
                                               providerRoot: "/r"))
        #expect(OrganizeScopeFilter.relation(of: finding, profileRoot: "/r",
                                             scope: scope) == .inside)
    }

    @Test func aScopeBelowTheSubjectStillSeesItAsAncestorContext() throws {
        let finding = StructureFinding(kind: .shape, family: "Health/Dental", schemes: [])
        let scope = try #require(OrganizeScope(path: "/r/Health/Dental/2025",
                                               providerRoot: "/r"))
        #expect(OrganizeScopeFilter.relation(of: finding, profileRoot: "/r",
                                             scope: scope) == .aboutAncestor)
    }
}

/// `visibleStructureFindings` is memoised: unmemoised, the duplicated-taxonomy pass over every
/// duplicate group, the sort-and-dedupe and the suppression filter would run two to four times
/// per Organize render. The memo is only as good as its key, so each test drives one input and
/// asserts the answer moved. A memo that never invalidated would pass none of them; one keyed on
/// the profile alone would pass only the last.
@MainActor
@Suite struct VisibleStructureFindingsMemoTests {

    private static let root = "/r"

    /// Two backlog families, so a suppression can be *moved* between them rather than only added —
    /// a key that counted suppressions instead of comparing them would survive that.
    private static func profile() -> FolderProfile {
        backlogProfile(families: ["Dental", "Vision"])
    }

    private func makeManager(extra: [String: (Int, Int)] = [:]) throws
        -> (manager: FileSyncManager, dir: URL) {
        try dentalManager("memo", families: ["Dental", "Vision"], extra: extra)
    }

    /// Suppressing one finding and un-suppressing it again — and then *moving* the suppression to
    /// a second finding, which leaves the set the same size and a different answer.
    @Test func aSuppressionThatMovesInvalidatesTheMemo() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backlogs = manager.visibleStructureFindings.filter { $0.kind == .backlog }
        #expect(backlogs.count == 2, "a positive control: two families fire")
        let first = backlogs[0], second = backlogs[1]

        let all = manager.visibleStructureFindings
        manager.restructureStore?.suppress(RestructureKey(first))
        let afterFirst = manager.visibleStructureFindings
        #expect(afterFirst.count == all.count - 1)
        #expect(!afterFirst.contains { $0.id == first.id })

        // Same suppression COUNT, different suppression.
        manager.restructureStore?.unsuppress(RestructureKey(first))
        manager.restructureStore?.suppress(RestructureKey(second))
        let afterMove = manager.visibleStructureFindings
        #expect(afterMove.count == afterFirst.count, "still exactly one suppression")
        #expect(afterMove.contains { $0.id == first.id }, "the first finding is back")
        #expect(!afterMove.contains { $0.id == second.id }, "the second is now hidden")
    }

    /// A different store carrying different suppressions replaces the answer, even though nothing
    /// about the profile moved.
    @Test func swappingTheStoreInvalidatesTheMemo() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        manager.restructureStore?.suppress(RestructureKey(finding))
        #expect(!manager.visibleStructureFindings.contains { $0.id == finding.id })

        let swapDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memo-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: swapDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: swapDir) }
        manager.restructureStore = RestructureStore(directory: swapDir, profileId: "t")
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id },
                "a fresh store suppresses nothing")

        manager.restructureStore = nil
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id },
                "and no store at all is the whole report")
    }

    /// Duplicated-taxonomy findings arrive with a duplicate scan, not with the profile, so the
    /// groups and the scan's root are both in the key. Driven three ways: the root alone, the
    /// groups alone, and an element rewrite that leaves the group count unchanged.
    @Test func theDuplicateScanInvalidatesTheMemo() throws {
        let (manager, dir) = try makeManager(extra: ["Papers": (0, 2),
                                                     "Papers/One": (4, 0), "Papers/Two": (4, 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        func group(_ name: String, _ folders: [String]) -> DuplicateGroup {
            papersGroup(name, in: folders, under: Self.root)
        }
        let pair = ["Papers/One", "Papers/Two"]
        let groups = ["a.pdf", "b.pdf", "c.pdf"].map { group($0, pair) }

        func taxonomyCount() -> Int {
            manager.visibleStructureFindings.filter { $0.kind == .duplicatedTaxonomy }.count
        }

        manager.duplicateGroups = groups
        #expect(taxonomyCount() == 0, "no scan root yet — the scan does not cover the survey")

        // The root alone flips the gate, with the groups untouched.
        manager.duplicateScanRoot = Self.root
        #expect(taxonomyCount() == 1, "a positive control: the detector fires")

        // An ELEMENT rewrite, not a wholesale replacement, and the count of groups is unchanged —
        // a key that watched `duplicateGroups.count` would miss this entirely.
        manager.duplicateGroups[2] = group("c.pdf", ["Papers/One", "Elsewhere"])
        #expect(taxonomyCount() == 0,
                "two matched documents is below the floor — the memo saw the element write")

        manager.duplicateGroups = []
        #expect(taxonomyCount() == 0)
        manager.duplicateGroups = groups
        #expect(taxonomyCount() == 1, "and it comes back")
    }

    /// A new profile replaces everything under the memo: the report, the folder universe the
    /// duplicated-taxonomy pass reads, and the answer.
    @Test func aNewProfileInvalidatesTheMemo() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!manager.visibleStructureFindings.isEmpty, "a positive control")
        manager.filingFolderProfile = FolderProfile(profileId: "t2", root: Self.root,
                                                    folders: [:], personTokens: [])
        #expect(manager.visibleStructureFindings.isEmpty)
        manager.filingFolderProfile = Self.profile()
        #expect(!manager.visibleStructureFindings.isEmpty)
    }

    /// A private stored property of `manager`, read by reflection. `structureReport` computes and
    /// caches on a miss, so asking it can never show whether the warm-up installed anything.
    private func stored<T>(_ label: String, of manager: FileSyncManager, as _: T.Type) -> T? {
        Mirror(reflecting: manager).children.first { $0.label == label }?.value as? T
    }

    private func warmUp(of manager: FileSyncManager) -> Task<Void, Never>? {
        stored("structureWarmUpTask", of: manager, as: Task<Void, Never>.self)
    }

    private func cachedReport(of manager: FileSyncManager) -> StructureReport? {
        stored("cachedStructureReport", of: manager, as: StructureReport.self)
    }

    /// The off-actor warm-up must never install a report for a profile that has since been
    /// replaced. A's warm-up is held past its cancellation check (`structureWarmUpGate`), B is
    /// installed and its own warm-up lands, then A is let go: only the generation token stands
    /// between A's report and the cache. Fails with that token check removed.
    @Test func aSupersededWarmUpNeverOverwritesTheCache() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await warmUp(of: manager)?.value   // the setup's own warm-up, out of the way
        #expect(!StructureDetectors.run(in: Self.profile()).findings.isEmpty,
                "premise: A's report, if installed, would show")

        let entered = Flag(), released = Flag(), timedOut = Flag()
        manager.structureWarmUpGate = {
            entered.value = true
            await parkUntilReleased(released, timedOut: timedOut)
        }
        manager.filingFolderProfile = Self.profile()   // A
        let superseded = try #require(warmUp(of: manager))
        await awaitArrival("A's warm-up never reached the gate") { entered.value }

        manager.structureWarmUpGate = nil
        manager.filingFolderProfile = FolderProfile(profileId: "t2", root: Self.root,
                                                    folders: [:], personTokens: [])   // B
        let current = try #require(warmUp(of: manager))
        await current.value
        let installed = try #require(cachedReport(of: manager), "B's warm-up installed nothing")
        #expect(installed.findings.isEmpty, "premise: the cache holds B's report")

        released.value = true
        await superseded.value
        #expect(!timedOut.value, "A's warm-up was let go by its bound, not by the test")
        #expect(cachedReport(of: manager)?.findings.isEmpty == true,
                "the superseded warm-up installed a report for the previous profile")
        #expect(manager.structureReport.findings.isEmpty)
    }

    /// …and the warm-up does land, for the profile that is current. Without this the test above
    /// would pass against a warm-up that never ran at all. Fails with `warmStructureReport()`
    /// dropped from the profile's `didSet`.
    @Test func theWarmUpInstallsAReportForTheCurrentProfile() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(cachedReport(of: manager) == nil,
                "premise: nothing computed the report synchronously, so only the warm-up can install it")
        let task = try #require(warmUp(of: manager), "setting the profile started no warm-up")
        await task.value
        let cached = try #require(cachedReport(of: manager), "the warm-up installed nothing")
        #expect(cached.findings.contains { $0.kind == .backlog })
        #expect(manager.visibleStructureFindings.contains { $0.kind == .backlog })
    }
}
