import Testing
@testable import Dashboard

/// Pins DetailsSidebar.MultiSelectionSummary: the pure string formatting for the details
/// sidebar's aggregate view shown when 2+ items are selected. Covers the "N items selected"
/// heading and the "N folders, M files" breakdown, including the singular/plural boundaries
/// and the folders-only / files-only / mixed / empty cases. No filesystem I/O — the size
/// summation lives separately in DetailsSidebar.computeMultiSelectionMetrics.
@Suite struct MultiSelectionSummaryTests {

    // MARK: Heading

    @Test func headingPluralizesItem() {
        #expect(DetailsSidebar.MultiSelectionSummary.heading(count: 0) == "0 items selected")
        #expect(DetailsSidebar.MultiSelectionSummary.heading(count: 1) == "1 item selected")
        #expect(DetailsSidebar.MultiSelectionSummary.heading(count: 2) == "2 items selected")
        #expect(DetailsSidebar.MultiSelectionSummary.heading(count: 17) == "17 items selected")
    }

    // MARK: Breakdown — single side only

    @Test func breakdownFoldersOnly() {
        // Singular boundary: exactly one folder.
        #expect(summary(folders: 1, files: 0).breakdown == "1 folder")
        // Plural.
        #expect(summary(folders: 3, files: 0).breakdown == "3 folders")
    }

    @Test func breakdownFilesOnly() {
        // Singular boundary: exactly one file.
        #expect(summary(folders: 0, files: 1).breakdown == "1 file")
        // Plural.
        #expect(summary(folders: 0, files: 5).breakdown == "5 files")
    }

    // MARK: Breakdown — mixed

    @Test func breakdownMixedPluralBothSides() {
        #expect(summary(folders: 2, files: 3).breakdown == "2 folders, 3 files")
    }

    @Test func breakdownMixedSingularBothSides() {
        // Both halves at their singular boundary.
        #expect(summary(folders: 1, files: 1).breakdown == "1 folder, 1 file")
    }

    @Test func breakdownMixedSingularFolderPluralFile() {
        #expect(summary(folders: 1, files: 4).breakdown == "1 folder, 4 files")
    }

    @Test func breakdownMixedPluralFolderSingularFile() {
        #expect(summary(folders: 6, files: 1).breakdown == "6 folders, 1 file")
    }

    // MARK: Breakdown — empty

    @Test func breakdownEmptyFallsBackToZeroItems() {
        // Defensive: an all-missing/empty selection still yields a sensible string rather
        // than an empty one.
        #expect(summary(folders: 0, files: 0).breakdown == "0 items")
    }

    private func summary(folders: Int, files: Int) -> DetailsSidebar.MultiSelectionSummary {
        DetailsSidebar.MultiSelectionSummary(folderCount: folders, fileCount: files)
    }
}
