import Testing
import Foundation
@testable import Sync

/// The one accessor rule: suppression is honoured at `visibleStructureFindings`, which every
/// surface reads, so the lens, the overview and the rail badge cannot disagree about what
/// "never suggest this again" meant.
@MainActor
@Suite struct RestructureVisibilityTests {

    private func makeManager() throws -> (manager: FileSyncManager, dir: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager()
        // A profile with one firing backlog family.
        var folders: [String: FolderProfileEntry] = [:]
        for (path, files, subs): (String, Int, Int) in [
            ("Dental", 0, 3),
            ("Dental/2023", 0, 1), ("Dental/2023/Claims", 2, 0),
            ("Dental/2024", 0, 1), ("Dental/2024/Claims", 2, 0),
            ("Dental/2025", 2, 0),
        ] {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: nil, fileCount: files,
                                               subfolderCount: subs, axes: [:])
        }
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: "/r",
                                                    folders: folders, personTokens: [])
        manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
        return (manager, dir)
    }

    @Test func aSuppressedFindingLeavesTheVisibleSetAndComesBackOnUnsuppress() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finding = try #require(manager.visibleStructureFindings.first {
            $0.kind == .backlog
        })

        manager.restructureStore?.suppress(RestructureKey(finding))
        #expect(!manager.visibleStructureFindings.contains { $0.id == finding.id })
        // The full report is untouched — suppression is a view fact, not a detector fact.
        #expect(manager.structureFindings.contains { $0.id == finding.id })

        manager.restructureStore?.unsuppress(RestructureKey(finding))
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id })
    }

    /// **Never suggest this again could not be taken back.** It now registers one ⌘Z step with an
    /// undoable banner, and Show them again brings back everything hidden.
    @Test func neverSuggestCanBeUndoneAndShownAgain() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })

        // A key for a folder that no longer produces a finding is not counted as hidden.
        let stale = RestructureKey(kind: .backlog, path: "Gone/Folder")
        manager.restructureStore?.suppress(stale)
        #expect(manager.hiddenStructureFindings(in: nil).isEmpty)

        undo.beginUndoGrouping()
        manager.suppressStructureFinding(finding)
        undo.endUndoGrouping()
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

    /// **Show them again counted the whole survey under a scoped list, and cleared every key.**
    /// It counts and brings back the hidden findings the scoped lens would show — inside the scope
    /// or about an ancestor of it — and leaves the ones outside it hidden.
    @Test func showingHiddenFindingsAgainStaysInTheLensScope() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A second family, outside the scope below.
        var folders = try #require(manager.filingFolderProfile).folders
        for (path, files, subs): (String, Int, Int) in [
            ("Vision", 0, 3),
            ("Vision/2023", 0, 1), ("Vision/2023/Claims", 2, 0),
            ("Vision/2024", 0, 1), ("Vision/2024/Claims", 2, 0),
            ("Vision/2025", 2, 0),
        ] {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: nil, fileCount: files,
                                               subfolderCount: subs, axes: [:])
        }
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: "/r",
                                                    folders: folders, personTokens: [])
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

    /// **A hidden §5.9 finding could not be shown again.** It comes from the duplicate scan, not
    /// the survey's report, and the hidden set read the report alone — so it was neither counted
    /// nor brought back, and nothing else lists it.
    @Test func aHiddenDuplicatedTaxonomyFindingCanBeShownAgain() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        var folders = try #require(manager.filingFolderProfile).folders
        for (path, files, subs): (String, Int, Int) in [
            ("Papers", 0, 2), ("Papers/One", 4, 0), ("Papers/Two", 4, 0),
        ] {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: nil, fileCount: files,
                                               subfolderCount: subs, axes: [:])
        }
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: "/r",
                                                    folders: folders, personTokens: [])
        manager.duplicateGroups = ["a.pdf", "b.pdf", "c.pdf"].map { name in
            DuplicateGroup(matchType: .sameText, name: name, isDirectory: false,
                           copies: ["Papers/One", "Papers/Two"].map {
                               DuplicateCopy(id: "/r/\($0)/\(name)", name: name,
                                             isDirectory: false, size: 10, itemCount: 1,
                                             modificationDate: nil, uniqueItemCount: 0, depth: 3,
                                             isRecommendedKeeper: false)
                           },
                           reclaimableBytes: 0)
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

    /// **⌘Z of Never suggest did nothing after a store swap.** A landing or survey refresh opens
    /// the new profile's store with the hidden set carried across; the undo cleared the key in the
    /// old store only, so the finding stayed hidden in the one the lens reads.
    @Test func undoingNeverSuggestReachesTheStoreThatReplacedTheOne() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })

        undo.beginUndoGrouping()
        manager.suppressStructureFinding(finding)
        undo.endUndoGrouping()

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
        // From disk: the swapped-out object is not what the undo writes through (L8).
        #expect(!RestructureStore(directory: dir, profileId: "t").isSuppressed(RestructureKey(finding)))
    }

    /// **⌘Z after a provider switch un-hid another profile's finding.** It cleared the key in
    /// whatever store was current — another profile's, where the same kind and path is a different
    /// folder's finding, hidden on its own. Only a store carried on from the one it was hidden in
    /// is reached; the switch carries nothing.
    @Test func undoingNeverSuggestLeavesAnotherProfilesStoreAlone() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        let original = try #require(manager.restructureStore)

        undo.beginUndoGrouping()
        manager.suppressStructureFinding(finding)
        undo.endUndoGrouping()

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

    /// **⌘Z after a renaming landing missed the re-keyed entry.** The landing moved the hidden key
    /// through its renames into the new store; the undo cleared the old spelling, which names
    /// nothing there. It now follows the same renames.
    @Test func undoingNeverSuggestFollowsTheLandingsRenames() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        let original = try #require(manager.restructureStore)
        let key = RestructureKey(finding)
        #expect(key.path.hasPrefix("Dental"), "premise: the rename below moves this key")

        undo.beginUndoGrouping()
        manager.suppressStructureFinding(finding)
        undo.endUndoGrouping()

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
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        let unrelated = RestructureKey(kind: .backlog, path: "Elsewhere/Folder")

        undo.beginUndoGrouping()
        manager.suppressStructureFinding(finding)
        undo.endUndoGrouping()
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

    /// The landing's re-derive is what records the lineage the undo follows: a rule nothing calls
    /// is one revert away from unused.
    @Test func theReDeriveRecordsTheLineage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileSyncManager+RestructureApply.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(source.contains("let newStore = RestructureStore(directory: profilesDirectory, profileId: newId)"))
        #expect(source.contains("newStore.adoptLineage(from: store, renames: RestructureRederive.renameMap(of: landed))"),
                "the re-derive swaps stores without recording which one it carried on from")
    }

    @Test func withNoStoreTheVisibleSetIsTheWholeReport() throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.restructureStore = nil
        #expect(manager.visibleStructureFindings == manager.structureFindings)
    }
}

/// The trend stamp reads the survey's own counts (proposal O16).
///
/// The store dedupes and the chart draws; this is the half in between — what goes INTO a point.
@MainActor
@Suite struct RestructureTrendStampTests {

    private func makeManager() throws -> (manager: FileSyncManager, dir: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trend-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager()
        var folders: [String: FolderProfileEntry] = [:]
        for (path, files, subs): (String, Int, Int) in [
            ("Dental", 0, 3),
            ("Dental/2023", 0, 1), ("Dental/2023/Claims", 2, 0),
            ("Dental/2024", 0, 1), ("Dental/2024/Claims", 2, 0),
            ("Dental/2025", 2, 0),
        ] {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: nil, fileCount: files,
                                               subfolderCount: subs, axes: [:])
        }
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: "/r",
                                                    folders: folders, personTokens: [])
        manager.filingProfileDirectoryId = "t"
        manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
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

    /// **Suppression does not move the line.** A trend that fell when the user hid a card would
    /// answer "is the tree getting better?" with "did you look away?".
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

    /// **The stamp costs nothing when there is nothing to record.** Reading the findings runs
    /// the whole detector sweep — 325 ms over the reference profile's 3,013 folders, measured —
    /// and the launch call site runs before the window appears. A profile already in the trend
    /// must be answered from the trend alone, without counting anything.
    ///
    /// Checked by making the count itself impossible: a manager with no profile cannot produce
    /// findings, so a stamp that reached the counting stage could not record the total below.
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

/// Scope relation reads the finding's SUBJECT (ROADMAP v5 §5.0): a backlog finding about
/// `Health/Dental/2025` under a scope pointed exactly there is work inside the scope, not an
/// ancestor note about `Health/Dental`.
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

/// `visibleStructureFindings` is memoised — it was recomputing §5.9's pass over every duplicate
/// group, the whole list's sort-and-dedupe and the suppression filter on every access, two to four
/// times per Organize render.
///
/// **The memo is only as good as its key**, so every one of these drives one input and asserts the
/// answer moved. A memo that never invalidated would pass none of them; one keyed on the profile
/// alone would pass only the last.
@MainActor
@Suite struct VisibleStructureFindingsMemoTests {

    private static let root = "/r"

    private static func entry(_ path: String, files: Int, subs: Int) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [], acceptsNewFiles: nil,
                           fileCount: files, subfolderCount: subs, axes: [:])
    }

    /// Two backlog families, so a suppression can be *moved* between them rather than only added —
    /// a key that counted suppressions instead of comparing them would survive that.
    private static func profile(extra: [String: (Int, Int)] = [:]) -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for family in ["Dental", "Vision"] {
            folders[family] = entry(family, files: 0, subs: 3)
            for year in ["2023", "2024"] {
                folders["\(family)/\(year)"] = entry("\(family)/\(year)", files: 0, subs: 1)
                folders["\(family)/\(year)/Claims"] = entry("\(family)/\(year)/Claims",
                                                            files: 2, subs: 0)
            }
            folders["\(family)/2025"] = entry("\(family)/2025", files: 2, subs: 0)
        }
        for (path, counts) in extra {
            folders[path] = entry(path, files: counts.0, subs: counts.1)
        }
        return FolderProfile(profileId: "t", root: root, folders: folders, personTokens: [])
    }

    private func makeManager(extra: [String: (Int, Int)] = [:]) throws
        -> (manager: FileSyncManager, dir: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = FileSyncManager()
        manager.filingFolderProfile = Self.profile(extra: extra)
        manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
        return (manager, dir)
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

    /// §5.9's findings arrive with a duplicate scan, not with the profile — so the groups and the
    /// scan's root are both in the key. Driven three ways: the root alone, the groups alone, and
    /// an element rewrite that leaves the group count unchanged.
    @Test func theDuplicateScanInvalidatesTheMemo() throws {
        let (manager, dir) = try makeManager(extra: ["Papers": (0, 2),
                                                     "Papers/One": (4, 0), "Papers/Two": (4, 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        func group(_ name: String, _ folders: [String]) -> DuplicateGroup {
            DuplicateGroup(matchType: .sameText, name: name, isDirectory: false,
                           copies: folders.map {
                               DuplicateCopy(id: "\(Self.root)/\($0)/\(name)", name: name,
                                             isDirectory: false, size: 10, itemCount: 1,
                                             modificationDate: nil, uniqueItemCount: 0, depth: 3,
                                             isRecommendedKeeper: false)
                           },
                           reclaimableBytes: 0)
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

    /// A new profile replaces everything under the memo — the report, the folder universe §5.9
    /// reads, and the answer.
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

    /// The off-actor warm-up must never install a report for a profile that has since been
    /// replaced. Set two profiles back to back, let the tasks land, and the answer must be the
    /// second one's — indefinitely.
    @Test func aSupersededWarmUpNeverOverwritesTheCache() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.filingFolderProfile = Self.profile()          // warm-up 1, immediately superseded
        manager.filingFolderProfile = FolderProfile(profileId: "t2", root: Self.root,
                                                    folders: [:], personTokens: [])
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 2_000_000)
            #expect(manager.structureReport.findings.isEmpty,
                    "the superseded warm-up installed a report for the previous profile")
        }
    }

    /// …and the warm-up does land, for the profile that is current. Without this the test above
    /// would pass against a warm-up that never ran at all.
    @Test func theWarmUpInstallsAReportForTheCurrentProfile() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Drain to the warm-up's install. It races the synchronous path by design, so the
        // observable claim is only that the answer is correct and stays correct.
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(manager.structureReport.findings.contains { $0.kind == .backlog })
        #expect(manager.visibleStructureFindings.contains { $0.kind == .backlog })
    }
}
