import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The two pure values behind the Compare Copies surface: the facts strip, and the wording of the
/// confirmation that destroys a file.
///
/// Both exist because the alternative is a rule written inside a `body`, where nothing can hold it
/// to its claims — the lesson `DuplicateRemovalPrompt` was extracted for, after the same-text
/// group's careful vocabulary drifted into "redundant copy" at the point of no return.
@Suite struct CompareCopiesModelsTests {

    private static let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func copy(_ path: String, size: Int = 1000, modified: Date? = noon,
                      keeper: Bool = false, protected: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: size, itemCount: 1, modificationDate: modified,
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper,
                      isProtectedFromRemoval: protected)
    }

    private func facts(_ left: DuplicateCopy, _ right: DuplicateCopy,
                       scanRoot: String? = "/Users/x/Docs", providerName: String? = "iCloud",
                       pages: (left: Int?, right: Int?)? = nil) -> ComparePairFacts {
        ComparePairFacts.make(left: left, right: right, scanRoot: scanRoot,
                              providerName: providerName, pages: pages)
    }

    private func row(_ f: ComparePairFacts, _ field: ComparePairFacts.Field) throws
        -> ComparePairFacts.Row {
        try #require(f.rows.first { $0.field == field })
    }

    // MARK: The strip's rows

    /// The plain case: same bytes, same date, two different folders.
    @Test func aPairInTwoFoldersDiffersOnlyByLocation() throws {
        let f = facts(copy("/Users/x/Docs/A/report.pdf"), copy("/Users/x/Docs/B/report.pdf"))
        #expect(try row(f, .name).differs == false)
        #expect(try row(f, .location).differs == true)
        #expect(try row(f, .size).differs == false)
        #expect(try row(f, .modified).differs == false)
        #expect(f.differingFields == [.location])
        #expect(f.everyResolvedRowAgrees == false)
    }

    /// **The trap the whole `differs` rule exists for.** A byte count renders to three significant
    /// figures, so two genuinely different sizes can print the same string. A strip that diffed
    /// its own labels would call these equal at the top of a surface whose entire job is to say
    /// whether two files are the same.
    @Test func twoSizesThatFormatAlikeAreStillFlaggedAsDiffering() throws {
        let f = facts(copy("/Users/x/Docs/A/r.pdf", size: 1_200_000),
                      copy("/Users/x/Docs/A/s.pdf", size: 1_200_400))
        let size = try row(f, .size)
        #expect(size.left == size.right, "the fixture no longer exercises the trap — pick sizes that format alike")
        #expect(size.differs == true, "the strip compared its own rendered labels")
    }

    /// The same trap on the other row: a date-only label collapses a six-hour edit, so the row
    /// carries a time and the comparison is on the `Date`.
    @Test func twoTimesOnOneDayAreVisiblyDifferentNotJustFlagged() throws {
        let later = Self.noon.addingTimeInterval(6 * 3600)
        let f = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/s.pdf", modified: later))
        let modified = try row(f, .modified)
        #expect(modified.differs == true)
        #expect(modified.left != modified.right,
                "the row says the dates differ and then prints the same string on both sides")
    }

    /// A copy with no recorded date renders an em dash rather than an empty cell, and still
    /// compares as different from one that has a date.
    @Test func aMissingDateReadsAsADashAndStillDiffers() throws {
        let f = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/s.pdf", modified: nil))
        #expect(try row(f, .modified).right == "—")
        #expect(try row(f, .modified).differs == true)
    }

    /// The location row states the FOLDER — the name is the row above it, and stating it twice is
    /// what made the card's breadcrumb need a second line.
    @Test func theLocationRowDropsTheFileNameAndKeepsTheScanRootCrumb() throws {
        let f = facts(copy("/Users/x/Docs/Legal/r.pdf"), copy("/Users/x/Docs/Legal/s.pdf"))
        #expect(try row(f, .location).left == "iCloud › Docs › Legal")
    }

    // MARK: Pages

    /// Page counts need the PDF serial lane, which may be queued behind a scan. Until both sides
    /// answer, the row claims nothing: not the same, not different.
    @Test func aPendingPageRowClaimsNothing() throws {
        let f = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/s.pdf"),
                      pages: (left: 12, right: nil))
        let pages = try row(f, .pages)
        #expect(pages.isPending == true)
        #expect(pages.differs == false)
        #expect(pages.right == "…")
        #expect(f.differingFields.contains(.pages) == false)
    }

    /// …and a pending row must not let a pair read as identical either. `everyResolvedRowAgrees`
    /// is what the identical-pair variant leans on, so a page count that never arrives cannot be
    /// the thing that makes two documents look the same.
    @Test func aPendingPageRowDoesNotMakeAPairLookIdentical() {
        let f = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/r.pdf"),
                      pages: (left: nil, right: nil))
        #expect(f.everyResolvedRowAgrees == true, "a pending row is not a disagreement")
        let resolved = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/r.pdf"),
                             pages: (left: 12, right: 9))
        #expect(resolved.everyResolvedRowAgrees == false)
    }

    @Test func pageTextPluralizes() {
        #expect(ComparePairFacts.pageText(1) == "1 page")
        #expect(ComparePairFacts.pageText(12) == "12 pages")
        #expect(ComparePairFacts.pageText(0) == "0 pages")
        #expect(ComparePairFacts.pageText(nil) == "…")
    }

    /// No pages argument means the pair is not paged at all — the row is absent rather than
    /// present and empty.
    @Test func anUnpagedPairHasNoPageRow() {
        let f = facts(copy("/Users/x/Docs/A/r.txt"), copy("/Users/x/Docs/A/s.txt"))
        #expect(f.rows.contains { $0.field == .pages } == false)
    }

    // MARK: The summary line

    /// The names differing is the PREMISE of a versions group, not a finding — so it stays a row
    /// and stays out of the summary.
    @Test func theSummaryIgnoresTheNameRow() {
        #expect(ComparePairFacts.summary(differing: [.name])
                    == "Every fact the scan recorded matches.")
        #expect(ComparePairFacts.summary(differing: [.name, .size]) == "Differs by size.")
    }

    @Test func theSummaryListsTwoAndThreeFieldsGrammatically() {
        #expect(ComparePairFacts.summary(differing: [.size, .modified])
                    == "Differs by size and date.")
        #expect(ComparePairFacts.summary(differing: [.location, .size, .modified])
                    == "Differs by location, size and date.")
    }

    @Test func theSummarySaysSoWhenNothingDiffers() {
        #expect(ComparePairFacts.summary(differing: []) == "Every fact the scan recorded matches.")
    }

    // MARK: The confirmation's wording

    /// The drift this type exists to prevent: a same-text pair has NOT been proved redundant, and
    /// the last sentence before a delete must not say it has.
    @Test func aSameTextPairIsNeverCalledRedundant() {
        let text = DuplicateComparePrompt.informativeText(
            kind: .sameText, keeperName: "Report.pdf", keeperLocation: "iCloud › Docs",
            reclaimText: "2.1 MB")
        #expect(!text.lowercased().contains("redundant"))
        #expect(text.contains("bytes differ"))
    }

    @Test func anIdenticalPairGetsNoWeakeningClause() {
        let text = DuplicateComparePrompt.informativeText(
            kind: .identical, keeperName: "Report.pdf", keeperLocation: "iCloud › Docs",
            reclaimText: "2.1 MB")
        #expect(!text.contains("bytes differ"))
        #expect(text.contains("Reclaims 2.1 MB"))
        #expect(text.contains("⌘Z"))
    }

    /// Versions discard genuinely different content. Saying so is the whole difference between a
    /// dedup and a deletion.
    @Test func aVersionsPairSaysTheOtherCopyIsNotACopy() {
        let text = DuplicateComparePrompt.informativeText(
            kind: .versions, keeperName: "Report.pdf", keeperLocation: "iCloud › Docs",
            reclaimText: "2.1 MB")
        #expect(text.contains("not copies"))
    }

    /// The budget means something only because the two interpolated names are bounded — otherwise
    /// the cap would measure the data rather than the sentence.
    @Test func everyKindsInformativeLineFitsTheBudget() {
        let longName = String(repeating: "supercalifragilistic", count: 6) + ".pdf"
        for kind in DuplicateMatchType.Kind.allCases {
            let text = DuplicateComparePrompt.informativeText(
                kind: kind, keeperName: longName,
                keeperLocation: "iCloud › Docs › Legal › Immigration",
                reclaimText: "2.1 MB")
            #expect(text.count <= DuplicateComparePrompt.lengthBudget,
                    "\(kind) runs \(text.count) characters")
        }
    }

    /// Middle-truncation, because the END of a file name is what tells two copies apart —
    /// "(1)" and the extension both live there.
    @Test func aLongNameIsTruncatedInTheMiddleKeepingItsExtension() {
        let name = String(repeating: "a", count: 60) + " (1).pdf"
        let out = DuplicateComparePrompt.truncated(name)
        #expect(out.count <= DuplicateComparePrompt.nameBudget)
        #expect(out.hasSuffix(".pdf"))
        #expect(out.contains("…"))
    }

    @Test func aShortNameIsLeftAlone() {
        #expect(DuplicateComparePrompt.truncated("Report.pdf") == "Report.pdf")
    }

    @Test func theQuestionNamesTheFileBeingDestroyed() {
        #expect(DuplicateComparePrompt.messageText(copyName: "Report (1).pdf")
                    == "Move “Report (1).pdf” to the Trash?")
    }

    /// A location the crumb derivation left empty (a file at the scan root itself) must not
    /// produce "Keeps “x” at . Reclaims…".
    @Test func anEmptyLocationDropsItsClauseRatherThanLeavingAStrandedAt() {
        let text = DuplicateComparePrompt.informativeText(
            kind: .identical, keeperName: "Report.pdf", keeperLocation: "", reclaimText: "2.1 MB")
        #expect(!text.contains(" at ."))
        #expect(text.hasPrefix("Keeps “Report.pdf”. Reclaims"))
    }

    // MARK: The disabled reason

    /// A greyed button with no reason reads as the app being broken — his report about the merge
    /// card's inert radios, in a different control.
    @Test func aProtectedCopySpellsOutWhyItCannotBeTrashed() throws {
        let reason = try #require(DuplicateComparePrompt.disabledReason(copyIsProtected: true,
                                                                       copyName: "Report.pdf"))
        #expect(reason.contains("Report.pdf"))
        #expect(reason.contains("keeping"))
        #expect(DuplicateComparePrompt.disabledReason(copyIsProtected: false,
                                                      copyName: "Report.pdf") == nil)
    }
}
