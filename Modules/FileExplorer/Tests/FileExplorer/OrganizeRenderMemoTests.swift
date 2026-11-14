import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The boxes that stop Organize recomputing the same answer on every publish. `LensWorkspaceView`
/// gets fresh closures from its parent, so it never equals itself and re-runs `body` each time.
/// ``LensWorkspaceView/RenderMemo`` holds what `body` derives and ``RestructurePlanSheet/TreeBox``
/// the plan sheet's disk view; both serve the stored answer only while the inputs are identical.
@MainActor
@Suite struct OrganizeRenderMemoTests {

    // MARK: RenderMemo

    @Test func aMemoRecomputesOnlyWhenItsKeyChanges() {
        let memo = LensWorkspaceView.RenderMemo<[String], Int>()
        var builds = 0
        func count(_ key: [String]) -> Int { memo.value(for: key) { builds += 1; return key.count } }

        #expect(count(["a", "b"]) == 2)
        #expect(builds == 1)
        #expect(count(["a", "b"]) == 2)
        #expect(count(["a", "b"]) == 2)
        #expect(builds == 1, "an unchanged key must not rebuild")

        #expect(count(["a", "b", "c"]) == 3)
        #expect(builds == 2, "a changed key must rebuild")
        // And back again: one slot, so the previous answer is gone rather than kept.
        #expect(count(["a", "b"]) == 2)
        #expect(builds == 3)
    }

    /// A memo whose value is `nil` still counts as computed: `scopeFolderCount` answers `Int?`, and
    /// "no scope, so no count" is an answer, not an empty slot to refill every render.
    @Test func aMemoHoldsAnOptionalNilAsAnAnswer() {
        let memo = LensWorkspaceView.RenderMemo<String, Int?>()
        var builds = 0
        func value(_ key: String) -> Int? { memo.value(for: key) { builds += 1; return nil } }
        #expect(value("k") == nil)
        #expect(value("k") == nil)
        #expect(builds == 1)
    }

    /// The rail and scope-chip keys change when what they describe changes; a key that ignored one
    /// of its inputs would serve a stale badge.
    @Test func theRailKeyMovesWithEveryListItCounts() {
        func key(suggestions: [FilingSuggestion] = [], rules: Int = 0,
                 scopes: [OrganizeScope?] = [nil], root: String = "~") -> LensWorkspaceView.RailCountsKey {
            LensWorkspaceView.RailCountsKey(
                suggestions: suggestions, duplicates: [], risky: [], renames: [], structure: [],
                rules: rules, profileRoot: root, scopes: scopes,
                hasSuggestedFiling: false, hasFoundDuplicates: false, hasScannedNames: false,
                hasProfile: false, filingScanFolder: nil, duplicateScanRoot: nil)
        }
        #expect(key() == key())
        #expect(key(rules: 1) != key())
        #expect(key(scopes: [OrganizeScope(path: "/a", providerRoot: "/")]) != key())
        #expect(key(root: "~/Documents") != key())
    }

/// The scope chip's count walks every folder in the profile, so its key carries the folder set, or
/// a re-derive would serve the last survey's number.
    @Test func theScopeFolderKeyMovesWithTheProfilesFolders() {
        func entry(_ path: String) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                               acceptsNewFiles: nil, noIntakeReason: nil,
                               fileCount: 0, subfolderCount: 0, axes: [:])
        }
        let scope = OrganizeScope(path: "/a", providerRoot: "/")
        let one = LensWorkspaceView.ScopeFolderKey(scope: scope, root: "~",
                                                   folders: ["A": entry("A")])
        let two = LensWorkspaceView.ScopeFolderKey(scope: scope, root: "~",
                                                   folders: ["A": entry("A"), "B": entry("B")])
        #expect(one == LensWorkspaceView.ScopeFolderKey(scope: scope, root: "~",
                                                        folders: ["A": entry("A")]))
        #expect(one != two, "a re-derived profile with a different folder set is a different key")
        #expect(one != LensWorkspaceView.ScopeFolderKey(scope: nil, root: "~",
                                                        folders: ["A": entry("A")]))
    }

    // MARK: TreeBox

    /// The cache must survive a re-render. `memoized()`'s cache lives as long as the view value, so
    /// a view built fresh inside the `.sheet` closure on every publish would never hit.
    @Test func theTreeBoxHoldsOneViewPerSubject() {
        let box = RestructurePlanSheet.TreeBox()
        var builds = 0
        var listings = 0
        func build() -> RestructureTreeView {
            builds += 1
            return RestructureTreeView(
                childFolders: { _ in listings += 1; return [] },
                files: { _ in listings += 1; return [] },
                fileCount: { _ in listings += 1; return 0 }).memoized()
        }

        _ = box.view(key: "shape|F|2013,2014", build: build).childFolders("F/2013")
        _ = box.view(key: "shape|F|2013,2014", build: build).childFolders("F/2013")
        _ = box.view(key: "shape|F|2013,2014", build: build).childFolders("F/2013")
        #expect(builds == 1, "the same subject must be served the same view")
        #expect(listings == 1, "and therefore the same cache — one listing, not three")

        _ = box.view(key: "shape|G|2013", build: build).childFolders("G/2013")
        #expect(builds == 2, "a different subject must not inherit the previous one's listings")
    }
}

/// The sheet wiring the boxes above depend on, pinned by source scan: only these prove the sheet
/// reads them.
@Suite struct RestructureSheetWiringTests {

    private func source(_ name: String) throws -> String { try SourceText.fileExplorer(name) }

    /// Every derivation reads the HELD view, not the one the parent handed in on this render.
    @Test func thePlanSheetDerivesAgainstTheHeldTree() throws {
        for name in ["RestructurePlanSheet.swift", "RestructurePairMergeSheet.swift"] {
            let text = try source(name)
            #expect(text.contains("treeBox.view(key:"),
                    "\(name): the sheet must hold its memoized view across renders")
            #expect(!text.contains("in: tree,") && !text.contains("in: tree)"),
                    "\(name): a derivation still reads the per-render `tree` — its cache is empty")
        }
    }

/// The review is frozen for the whole of a landing: each of its ~101 progress ticks re-renders the
/// sheet, and would re-run the planner against a tree the executor is moving.
    @Test func theReviewIsFrozenWhileTheLandingRuns() throws {
        let sheet = try source("RestructurePlanSheet.swift")
        #expect(sheet.contains("let plan = landedPlan ?? applyingPlan ?? derived"),
                "the single plan must consult the in-flight freeze before re-deriving")
        #expect(sheet.contains("let group = Self.shownGroup(landed: landedGroup, applying: applyingGroup,"),
                "and so must the group's, which runs the planner once per family (`RestructureGroupTableSurfaceTests` pins `shownGroup`)")
        // Armed with the flag it belongs to, and cleared on the path where nothing landed.
        #expect(sheet.contains("applyingPlan = .success(manifest)"))
        #expect(sheet.contains("applyingGroup = plans"))
        #expect(sheet.contains("applyingPlan = nil"))

        let pair = try source("RestructurePairMergeSheet.swift")
        #expect(pair.contains("if let applyingManifest { return .success(applyingManifest) }"))
        #expect(pair.contains("applyingManifest = manifest"))
    }

    /// The sibling walk runs after the first frame, not inside `.onAppear` in front of it.
    @Test func theSiblingWalkRunsAfterTheFirstFrame() throws {
        let sheet = try source("RestructurePlanSheet.swift")
        #expect(sheet.contains(".task { seedGroupPointer() }"),
                "the several-hundred-listing sibling walk must not block the sheet's first paint")
        // And `seed()` must not have kept a copy of it, anywhere in its own body.
        let seedBody = try SourceText.body(of: "private func seed() {", in: sheet)
        #expect(!seedBody.contains("parallelFamilies(of:"),
                "`seed()` still walks the siblings — the move bought nothing")
    }
}

/// Work the Restructure lens must not redo on every render, as rules that can be asserted
/// without mounting it.
@MainActor
@Suite struct RestructureLensPerRenderTests {

/// The chips' counts agree with the lists they label, without filtering and sorting the dead-weight
/// map three times per render.
    @Test func theCrowdingCountAgreesWithTheListItLabels() {
        let deadWeight: [String: DeadWeightClass] = [
            "A": .empty, "B": .empty, "C": .passThrough,
            "D/E": .singleFileLeaf, "F": .singleFileLeaf, "G": .singleFileLeaf,
        ]
        #expect(RestructureLens.crowdingCount(deadWeight, .empty) == 2)
        #expect(RestructureLens.crowdingCount(deadWeight, .passThrough) == 1)
        #expect(RestructureLens.crowdingCount(deadWeight, .singleFileLeaf) == 3)
        #expect(RestructureLens.crowdingCount([:], .empty) == 0)
    }

/// The cached stamp formatters follow the system zone, or after a flight a landing stamped this
/// morning reads an hour out. Driven through the accessor: moving `NSTimeZone.default` is
/// process-wide and would race every other suite.
    @Test func theStampFormattersFollowTheSystemZone() throws {
        let elsewhere = try #require([TimeZone(identifier: "Asia/Kolkata"),
                                      TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })
        RestructureLens.stampClock.stageZoneForTesting(elsewhere)
        _ = RestructureLens.stampClock.string(from: Date())
        #expect(RestructureLens.stampClock.zone == TimeZone.current,
                "a cached formatter must be put back on the system zone before it is used")
        // The reading itself, so this is not only about a property.
        let stamp = "2026-08-28T09:14:00"
        RestructureLens.stampParser.stageZoneForTesting(elsewhere)
        let now = try #require(RestructureLens.stampParser.date(from: "2026-08-28T12:00:00"))
        #expect(RestructureLens.landingPhrase(stamp, now: now, locale: Locale(identifier: "en_GB"))
                == "today at 09:14")
    }
}
