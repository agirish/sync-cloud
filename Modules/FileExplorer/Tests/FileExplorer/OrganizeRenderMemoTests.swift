import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// **The boxes that stop Organize recomputing the same answer on every publish.**
///
/// `LensWorkspaceView` is handed about thirty fresh closures by its parent, so it is never equal
/// to itself and SwiftUI re-runs `body` on every publish the manager makes. Two things hang off
/// that: the counts and lists `body` derives (``LensWorkspaceView/RenderMemo``), and the plan
/// sheet's memoized disk view, which `LensWorkspaceView` was minting fresh — and therefore EMPTY
/// — inside its `.sheet` content closure (``RestructurePlanSheet/TreeBox``).
///
/// The rule both must satisfy is the same one: serve the stored answer only while the inputs are
/// identical, and never a stale one.
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
        // And back again — one slot, so the previous answer is gone rather than kept.
        #expect(count(["a", "b"]) == 2)
        #expect(builds == 3)
    }

    /// A memo whose value is `nil` still counts as computed — `scopeFolderCount` answers `Int?`,
    /// and "no scope, so no count" is an answer, not an empty slot to fill again every render.
    @Test func aMemoHoldsAnOptionalNilAsAnAnswer() {
        let memo = LensWorkspaceView.RenderMemo<String, Int?>()
        var builds = 0
        func value(_ key: String) -> Int? { memo.value(for: key) { builds += 1; return nil } }
        #expect(value("k") == nil)
        #expect(value("k") == nil)
        #expect(builds == 1)
    }

    /// The keys the rail and the scope chip are memoised on really do change when the thing they
    /// describe changes — a key that ignored one of its inputs would serve a stale badge.
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

    /// The scope chip's count is a walk of every folder in the profile, so its key has to carry
    /// the folder set — a key of scope-and-root alone would serve last survey's number after a
    /// re-derive, which is precisely when the count changes.
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

    /// **The cache has to survive a re-render, which is the entire defect.** `memoized()`'s cache
    /// lives as long as the view VALUE, and the parent built a fresh one inside its `.sheet`
    /// content closure on every publish — so the sheet's documented memoisation never once hit in
    /// the app.
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

/// **The wiring the boxes above only help if the sheet actually uses**, pinned by source scan.
///
/// The unit tests next door prove `TreeBox` and the frozen plan behave; they cannot prove the
/// sheet reads them. These are the same kind of assertion as
/// `thePlanSheetWiringGoesThroughPlanDiskRoot` — the shipped defect it guards was likewise a call
/// site, not a rule.
@Suite struct RestructureSheetWiringTests {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

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

    /// The review is frozen for the DURATION of a landing, not merely after it.
    ///
    /// A landing publishes up to ~101 gated progress ticks and each one re-renders the sheet;
    /// with only the after-the-fact freeze in place, every tick re-ran the planner against a tree
    /// the executor was in the middle of moving.
    @Test func theReviewIsFrozenWhileTheLandingRuns() throws {
        let sheet = try source("RestructurePlanSheet.swift")
        #expect(sheet.contains("let plan = landedPlan ?? applyingPlan ?? derived"),
                "the single plan must consult the in-flight freeze before re-deriving")
        #expect(sheet.contains("let group = landedGroup ?? applyingGroup ?? "),
                "and so must the group's, which runs the planner once per family")
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
        // And `seed()` must not have kept a copy of it.
        let seedBody = try #require(sheet.range(of: "private func seed() {").map {
            String(sheet[$0.upperBound...].prefix(1600))
        })
        #expect(!seedBody.contains("parallelFamilies(of:"),
                "`seed()` still walks the siblings — the move bought nothing")
    }
}

/// **What the Restructure lens stopped doing on every render**, as rules that can be asserted
/// without mounting it.
@MainActor
@Suite struct RestructureLensPerRenderTests {

    /// The chips report a COUNT and used to get it by filtering, mapping and **sorting** the
    /// ~609-entry dead-weight map — three times per render, once per class. Counting and listing
    /// have to agree, or a chip is labelling a list it does not describe.
    @Test func theCrowdingCountAgreesWithTheListItLabels() {
        let deadWeight: [String: DeadWeightClass] = [
            "A": .empty, "B": .empty, "C": .passThrough,
            "D/E": .singleFileLeaf, "F": .singleFileLeaf, "G": .singleFileLeaf,
        ]
        #expect(RestructureLens.crowdingCount(deadWeight, .empty) == 2)
        #expect(RestructureLens.crowdingCount(deadWeight, .passThrough) == 1)
        #expect(RestructureLens.crowdingCount(deadWeight, .singleFileLeaf) == 3)
        // Against the list itself, class by class — the assertion that catches a count that has
        // stopped reading the class it was asked about.
        for weightClass in [DeadWeightClass.empty, .passThrough, .singleFileLeaf] {
            let listed = deadWeight.filter { $0.value == weightClass }.map(\.key).sorted()
            #expect(RestructureLens.crowdingCount(deadWeight, weightClass) == listed.count,
                    "\(weightClass): the chip's number and its list disagree")
        }
        #expect(RestructureLens.crowdingCount([:], .empty) == 0)
    }

    /// **The cached stamp formatters follow the system zone.**
    ///
    /// `landingPhrase` and `absolute` built two or three `DateFormatter`s per Applied card per
    /// render; they are cached now. A cached formatter keeps whichever zone was current when it
    /// was built, so a landing stamped this morning would read an hour out after a flight — the
    /// one behaviour a fresh-per-call formatter had for free. Driven through the accessor rather
    /// than by moving `NSTimeZone.default`, which is process-wide and would race every other
    /// suite in the run.
    @Test func theStampFormattersFollowTheSystemZone() throws {
        let elsewhere = try #require([TimeZone(identifier: "Asia/Kolkata"),
                                      TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })
        let formatter = RestructureLens.formatter("HH:mm")
        formatter.timeZone = elsewhere
        #expect(RestructureLens.formatter("HH:mm").timeZone == TimeZone.current,
                "a cached formatter must be put back on the system zone before it is used")
        // The reading itself, so this is not only about a property.
        let stamp = "2026-08-28T09:14:00"
        RestructureLens.formatter("yyyy-MM-dd'T'HH:mm:ss").timeZone = elsewhere
        let now = try #require(RestructureLens.formatter("yyyy-MM-dd'T'HH:mm:ss")
            .date(from: "2026-08-28T12:00:00"))
        #expect(RestructureLens.landingPhrase(stamp, now: now) == "today at 09:14")
    }
}
