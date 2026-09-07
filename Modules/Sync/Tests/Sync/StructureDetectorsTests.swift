import Testing
import Foundation
@testable import Sync

/// The seven new detectors, each proved three ways (ROADMAP_V5 §5.2): a synthetic fixture that
/// fires, a control that stays silent, and the reference tree with its count pinned — a detector
/// whose count moves on the fixture moves for a reason someone has to write down.
@Suite struct StructureDetectorsTests {

    // MARK: Builders

    private static func entry(_ path: String, files: Int = 0, subfolders: Int = 0,
                              axes: [String: String] = [:]) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                           acceptsNewFiles: nil, fileCount: files, subfolderCount: subfolders,
                           axes: axes)
    }

    /// paths as (path, files, subfolders); subfolder counts are derived when omitted.
    private static func profile(_ entries: [(String, Int, Int)]) -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for (path, files, subfolders) in entries {
            folders[path] = entry(path, files: files, subfolders: subfolders)
        }
        return FolderProfile(profileId: "test", root: "/root", folders: folders, personTokens: [])
    }

    private static func report(_ entries: [(String, Int, Int)]) -> StructureReport {
        StructureDetectors.run(in: profile(entries))
    }

    private static func findings(_ entries: [(String, Int, Int)],
                                 _ kind: FindingKind) -> [StructureFinding] {
        report(entries).findings.filter { $0.kind == kind }
    }

    static var referenceReport: StructureReport {
        get throws {
            StructureDetectors.run(in: try RestructureFixturesTests.profile(
                named: "restructure-reference-tree"))
        }
    }

    // MARK: Backlog

    @Test func backlogFiresWhenTheNewestYearHoldsFilesAndNoFolders() {
        let hits = Self.findings([
            ("Health/Dental", 0, 3),
            ("Health/Dental/2023", 0, 2),
            ("Health/Dental/2023/Claims", 4, 0),
            ("Health/Dental/2023/Statements", 2, 0),
            ("Health/Dental/2024", 0, 2),
            ("Health/Dental/2024/Claims", 5, 0),
            ("Health/Dental/2024/Statements", 1, 0),
            ("Health/Dental/2025", 2, 0),
        ], .backlog)
        #expect(hits.map(\.subject) == ["Health/Dental/2025"])
        #expect(hits.first?.detail == .backlog(scaffold: ["Claims", "Statements"], looseFiles: 2))
    }

    @Test func backlogScaffoldCarriesDiskSpellingNotVocabularyCase() {
        // The vocabulary comparison lowercases; the scaffold must not — a `claims/` scaffold on
        // a tree that spells it `Claims/` would be a divergence created by this tool.
        let hits = Self.findings([
            ("A", 0, 2),
            ("A/2023", 0, 1), ("A/2023/MiXeD Case", 1, 0),
            ("A/2024", 0, 1), ("A/2024/MiXeD Case", 1, 0),
            ("A/2025", 3, 0),
        ], .backlog)
        #expect(hits.first?.detail == .backlog(scaffold: ["MiXeD Case"], looseFiles: 3))
    }

    @Test func backlogWithOneShapedSiblingFiresWithAnEmptyScaffold() {
        // One shaped sibling makes the flatness a finding, but its layout is not a convention —
        // a lone member's idiosyncrasy must not become next year's folders.
        let hits = Self.findings([
            ("B", 0, 2),
            ("B/2024", 1, 1), ("B/2024/Archive", 2, 0),
            ("B/2025", 5, 0),
        ], .backlog)
        #expect(hits.map(\.subject) == ["B/2025"])
        #expect(hits.first?.detail == .backlog(scaffold: [], looseFiles: 5))
    }

    @Test func backlogStaysSilentWhenTheNewestYearIsShapedOrEmptyOrAlone() {
        // Newest is shaped: nothing to say.
        #expect(Self.findings([
            ("A", 0, 2),
            ("A/2024", 0, 1), ("A/2024/Claims", 1, 0),
            ("A/2025", 0, 1), ("A/2025/Claims", 1, 0),
        ], .backlog).isEmpty)
        // Newest is flat but EMPTY: nothing waiting to be filed.
        #expect(Self.findings([
            ("B", 0, 2),
            ("B/2024", 0, 1), ("B/2024/Claims", 1, 0),
            ("B/2025", 0, 0),
        ], .backlog).isEmpty)
        // No shaped sibling at all: the family files flat and 2025 matches its siblings.
        #expect(Self.findings([
            ("C", 0, 3),
            ("C/2023", 2, 0), ("C/2024", 3, 0), ("C/2025", 1, 0),
        ], .backlog).isEmpty)
    }

    // MARK: Shadow axis

    @Test func shadowAxisNamesAYearHidingInARoleNameBesideBareYears() {
        let hits = Self.findings([
            ("Tax", 0, 3),
            ("Tax/2022", 1, 0), ("Tax/2023", 1, 0),
            ("Tax/IRS Docs - 2023", 2, 0),
        ], .shadowAxis)
        #expect(hits.map(\.subject) == ["Tax/IRS Docs - 2023"])
        #expect(hits.first?.detail == .shadowAxis(target: "2023", targetExists: true))
    }

    @Test func shadowAxisSaysWhenItsTargetYearDoesNotExistYet() {
        let hits = Self.findings([
            ("Trips", 0, 3),
            ("Trips/2021", 1, 0), ("Trips/2022", 1, 0),
            ("Trips/2023 (Family)", 2, 0),
        ], .shadowAxis)
        #expect(hits.first?.detail == .shadowAxis(target: "2023", targetExists: false))
    }

    @Test func shadowAxisIgnoresRangesAndFamiliesWithNoBareYears() {
        // A fiscal span carries two years — an axis value of its own, not a shadow of either.
        #expect(Self.findings([
            ("IN", 0, 3),
            ("IN/2022", 1, 0), ("IN/2023", 1, 0),
            ("IN/2005 - 2006", 2, 0),
        ], .shadowAxis).isEmpty)
        // Monthly statement folders sit among months, not years — the family itself must
        // testify that bare years are its convention.
        #expect(Self.findings([
            ("Statements", 0, 2),
            ("Statements/01. Jan 2019", 1, 0), ("Statements/02. Feb 2019", 1, 0),
        ], .shadowAxis).isEmpty)
    }

    // MARK: Echo name

    @Test func echoNameCatchesAChildRestatingItsParent() {
        let hits = Self.findings([
            ("Utilities/PG&E", 0, 1),
            ("Utilities/PG&E/PGE", 3, 0),
        ], .echoName)
        #expect(hits.map(\.subject) == ["Utilities/PG&E/PGE"])
        #expect(hits.first?.detail == .echoName(counterpart: "Utilities/PG&E",
                                                relation: .parentChild))
    }

    @Test func echoNameCatchesTwoSiblingsSpellingOneName() {
        let hits = Self.findings([
            ("Forms", 0, 2),
            ("Forms/Form W-2", 2, 0),
            ("Forms/Form W2", 1, 0),
        ], .echoName)
        #expect(hits.map(\.subject) == ["Forms/Form W2"])
        #expect(hits.first?.detail == .echoName(counterpart: "Forms/Form W-2",
                                                relation: .sibling))
    }

    @Test func threeSpellingsOfOneNameYieldTwoDistinctIdentities() {
        let hits = Self.findings([
            ("F", 0, 3),
            ("F/W-2", 1, 0), ("F/W2", 1, 0), ("F/W 2", 1, 0),
        ], .echoName)
        #expect(hits.count == 2)
        #expect(Set(hits.map(\.id)).count == 2)
    }

    @Test func echoNameLeavesGenuinelyDifferentSiblingsAlone() {
        #expect(Self.findings([
            ("F", 0, 2),
            ("F/Form W-2", 1, 0), ("F/Form 1099", 1, 0),
        ], .echoName).isEmpty)
    }

    // MARK: Mirrored inbox

    @Test func mirroredInboxFindsTheDestinationTheInboxShadows() {
        let hits = Self.findings([
            ("Health", 0, 2),
            ("Health/Dental", 4, 0),
            ("Health/TODO", 0, 1),
            ("Health/TODO/Dental", 2, 0),
        ], .mirroredInbox)
        #expect(hits.map(\.subject) == ["Health/TODO/Dental"])
        #expect(hits.first?.detail == .mirroredInbox(destination: "Health/Dental"))
    }

    @Test func onlyTheShallowestMirrorInASubtreeFires() {
        // `TODO/Dental/Claims` mirroring `Dental/Claims` is the inside of the `TODO/Dental`
        // finding, not a second one — the plan that merges the mirror carries it.
        let hits = Self.findings([
            ("Health", 0, 2),
            ("Health/Dental", 0, 1), ("Health/Dental/Claims", 3, 0),
            ("Health/TODO", 0, 1),
            ("Health/TODO/Dental", 0, 1), ("Health/TODO/Dental/Claims", 2, 0),
        ], .mirroredInbox)
        #expect(hits.map(\.subject) == ["Health/TODO/Dental"])
    }

    @Test func theInboxItselfAndUnmirroredContentsAreNotFindings() {
        // Health/TODO trivially "mirrors" Health with its component removed; Health/TODO/Vision
        // has no Health/Vision to mirror. Neither is a finding.
        #expect(Self.findings([
            ("Health", 0, 2),
            ("Health/Dental", 4, 0),
            ("Health/TODO", 0, 1),
            ("Health/TODO/Vision", 2, 0),
        ], .mirroredInbox).isEmpty)
    }

    // MARK: Loose above a series

    @Test func looseAboveSeriesFiresOnFilesParkedAboveAYearRun() {
        let hits = Self.findings([
            ("Fidelity/Statements", 5, 4),
            ("Fidelity/Statements/2019", 3, 0), ("Fidelity/Statements/2020", 3, 0),
            ("Fidelity/Statements/2021", 3, 0), ("Fidelity/Statements/2022", 3, 0),
        ], .looseAboveSeries)
        #expect(hits.map(\.subject) == ["Fidelity/Statements"])
        #expect(hits.first?.detail == .looseAboveSeries(looseFiles: 5, seriesFolders: 4))
        // family == subject is what groups this with a shape finding about the same folder.
        #expect(hits.first?.family == "Fidelity/Statements")
    }

    @Test func looseAboveSeriesHasAFloorOnBothNumbers() {
        // Two years is not a series.
        #expect(Self.findings([
            ("A", 9, 2), ("A/2021", 1, 0), ("A/2022", 1, 0),
        ], .looseAboveSeries).isEmpty)
        // Three parked files is an accident, not a habit (the floor is 4).
        #expect(Self.findings([
            ("B", 3, 3), ("B/2020", 1, 0), ("B/2021", 1, 0), ("B/2022", 1, 0),
        ], .looseAboveSeries).isEmpty)
    }

    // MARK: Loose beside a container

    @Test func looseBesideContainerPointsALeafAtTheContainerItRestates() {
        let hits = Self.findings([
            ("Home", 0, 2),
            ("Home/ATT", 0, 3),
            ("Home/ATT Bill", 2, 0),
        ], .looseBesideContainer)
        #expect(hits.map(\.subject) == ["Home/ATT Bill"])
        #expect(hits.first?.detail == .looseBesideContainer(container: "Home/ATT"))
    }

    @Test func looseBesideContainerNeedsALeafAContainerAndLetters() {
        // The "loose" one has subfolders of its own: a parallel family, not a stray.
        #expect(Self.findings([
            ("I", 0, 2), ("I/H-4", 0, 3), ("I/H-4 EAD", 0, 2),
        ], .looseBesideContainer).isEmpty)
        // The "container" is a flat pile: moving accounts into it is the finding backwards.
        #expect(Self.findings([
            ("A", 0, 2), ("A/HDFC", 14, 0), ("A/HDFC Savings", 2, 3),
        ], .looseBesideContainer).isEmpty)
        // Version numbers tokenise into subsets of each other; all-digit names are skipped.
        #expect(Self.findings([
            ("R", 0, 2), ("R/5.1.1", 2, 1), ("R/5.2.1", 3, 0),
        ], .looseBesideContainer).isEmpty)
    }

    // MARK: Dead weight

    @Test func deadWeightClassifiesTheThreeShapesAndNothingElse() {
        let report = Self.report([
            ("A", 0, 1),          // pass-through
            ("A/B", 1, 0),        // single-file leaf
            ("C", 0, 0),          // empty
            ("D", 3, 2),          // ordinary — no class
        ])
        #expect(report.deadWeight["A"] == .passThrough)
        #expect(report.deadWeight["A/B"] == .singleFileLeaf)
        #expect(report.deadWeight["C"] == .empty)
        #expect(report.deadWeight["D"] == nil)
        #expect(report.findings.filter { $0.kind == .deadWeight }.isEmpty,
                "crowding is a property of the scope, never a card")
    }

    // MARK: Grouping and identity

    @Test func aFoldersRowsSortTogetherAndKindsKeepTheirDeclaredOrder() throws {
        // Finance/US/Income Tax produces a shape finding AND a loose-above finding — the measured
        // overlap §5.0's grouping rule exists for. Same subject, adjacent rows, shape first.
        let report = try Self.referenceReport
        let incomeTax = report.findings.enumerated()
            .filter { $0.element.subject == "Finance/US/Income Tax" }
        #expect(incomeTax.map(\.element.kind) == [.shape, .looseAboveSeries])
        let indices = incomeTax.map(\.offset)
        #expect(indices == Array(indices.first!...indices.last!), "rows about one folder scatter")
    }

    @Test func everyFindingIdIsUniqueAcrossTheWholeReferenceTree() throws {
        let findings = try Self.referenceReport.findings
        #expect(Set(findings.map(\.id)).count == findings.count)
    }

    // MARK: The reference tree, pinned

    /// The full detector set over the reference tree — every count the roadmap's §5.2 table now
    /// carries, measured through the Swift detectors on 2026-08-28. A movement here is a rule
    /// change or a fixture re-lift, and either one is a decision, not a drift.
    @Test func theReferenceTreeCountsArePinned() throws {
        let report = try Self.referenceReport
        var byKind: [FindingKind: Int] = [:]
        for finding in report.findings { byKind[finding.kind, default: 0] += 1 }
        #expect(byKind == [.shape: 1, .backlog: 11, .shadowAxis: 3, .echoName: 5,
                           .looseAboveSeries: 11, .looseBesideContainer: 2])

        let weights = report.deadWeight.values
        #expect(weights.count { $0 == .passThrough } == 86)
        #expect(weights.count { $0 == .singleFileLeaf } == 503)
        #expect(weights.count { $0 == .empty } == 20)
    }

    /// The named hits, not just the counts — a count of 2 that swapped a real hit for junk would
    /// pass a count pin.
    @Test func theReferenceTreeNamedHitsAreTheRoadmaps() throws {
        let findings = try Self.referenceReport.findings
        func subjects(_ kind: FindingKind) -> Set<String> {
            Set(findings.filter { $0.kind == kind }.map(\.subject))
        }
        #expect(subjects(.looseBesideContainer)
            == ["School/US/Son/City Pre-K", "Work/EMP/Products/Nova PE"])
        #expect(subjects(.shadowAxis).contains("Finance/US/Income Tax/IRS Docs - 2023"))
        #expect(subjects(.backlog).contains("Health/Dental/2025"))
        #expect(subjects(.backlog).contains("Work/EMP/Compensation/Benefits/2026"))
        #expect(subjects(.looseAboveSeries).contains("Finance/US/Investments/Fidelity/Statements"))
        #expect(subjects(.echoName).contains("Finance/US/Income Tax/2023/Forms/Form W2"))
        // The degenerate Finance/US/TODO/IRS/IRS is parent/child echo's observation, not
        // mirrored inbox's — the 6 Aug TODO drain cleared the class mirrored inbox detects,
        // so its reference count is zero and its firing case is the synthetic one above.
        #expect(subjects(.mirroredInbox).isEmpty)
        #expect(subjects(.echoName).contains("Finance/US/TODO/IRS/IRS"))
    }

    // MARK: The reserved kind

    /// **`FindingKind.ask` is reserved, and this is what makes that word checkable.**
    ///
    /// Nothing constructs one: §5.3's detector is not in 5.0. The case exists so that landing it
    /// later is a detector and nothing else — `carriesPlan`, the lens's glyph, symbol and verb
    /// all already answer for it. But a case with rules and no producer reads, in every one of
    /// those switches, exactly like a case that ships; the type's own doc said so in prose until
    /// this test was written, and prose is the thing that goes stale silently.
    ///
    /// Scans every source that could construct one — `Modules/*/Sources`, `MacApp` and the CLI —
    /// because "no detector produces it" is a claim about the whole app, not about the file the
    /// enum lives in. **The pathspec is the conclusion's boundary**, so it is asserted, and so is
    /// the scan's ability to find a construction at all.
    @Test func nothingConstructsTheReservedAskKind() throws {
        let sources = try Self.appAndCLISwiftSources()
        var offenders: [String] = []
        var controls = 0
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            // The two spellings a construction can take: the labelled initialiser argument, and
            // the manifest/key builders that pass a kind positionally as `kind:`.
            if text.contains("kind: .ask") { offenders.append(url.lastPathComponent) }
            if text.contains("kind: .echoName") || text.contains("kind: .backlog") { controls += 1 }
        }
        #expect(offenders.isEmpty,
                "a detector now produces .ask (\(offenders.joined(separator: ", "))) — the case is no longer reserved, so StructureDivergence's note and the lens's verb, glyph and tint rules all need to be about a kind that ships")
        #expect(controls > 0,
                "the scan found no `kind: .<case>` construction anywhere, so its empty result about .ask says nothing — the roots or the spelling are wrong")
    }

    /// `Modules/*/Sources`, `MacApp` and `SyncCloudCLI/Sources`. The CLI is the addition over the
    /// Design scans' roots: it builds findings of its own to report, so a scan that skipped it
    /// would answer about the app and be read as answering about the product.
    private static func appAndCLISwiftSources() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let modules = repo.appendingPathComponent("Modules")
        var roots = [repo.appendingPathComponent("MacApp"),
                     repo.appendingPathComponent("SyncCloudCLI/Sources")]
        roots += try FileManager.default
            .contentsOfDirectory(at: modules, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Sources") }

        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            files += FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }
        #expect(files.count > 100, "found only \(files.count) sources — the roots did not resolve")
        #expect(files.contains { $0.path.hasSuffix("Sync/StructureDivergence.swift") },
                "the module the kind lives in is not being scanned")
        #expect(files.contains { $0.path.contains("SyncCloudCLI/Sources/") },
                "the CLI is not being scanned")
        #expect(!files.contains { $0.path.contains("/.build/") }, "a dependency source leaked in")
        return files
    }
}
