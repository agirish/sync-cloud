import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The two pure values behind the Compare Copies surface: the facts strip, and the wording of the
/// confirmation that destroys a file.
/// Both are values, like `DuplicateRemovalPrompt`, because a rule written inside a `body` can't be
/// held to its claims, and wording at the point of no return must not drift.
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
        #expect(f.summary == "Differs by location.")
    }

    /// The trap the `differs` rule exists for: a byte count renders to three significant figures,
    /// so two different sizes print alike, and a strip that diffed its own labels would call them equal.
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

    /// The location row states the folder only: the name is the row above, and repeating it
    /// pushes the breadcrumb onto a second line.
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

    /// …and a pending row must not let a pair read as identical either. Asserted through
    /// ``ComparePairFacts/summary``, the sentence the bar says: a page count in flight leaves
    /// `differingFields` empty, and the absolute claim would be made when least is known.
    @Test func aPendingPageRowDoesNotMakeAPairLookIdentical() {
        let pending = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/r.pdf"),
                            pages: (left: nil, right: nil))
        #expect(pending.summary == "Every fact the scan recorded matches — one is still being read.",
                "a pair whose page count had not arrived claimed every fact matched")

        let differing = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/r.pdf"),
                              pages: (left: 12, right: 9))
        #expect(differing.summary == "Differs by page count.")

        // The positive control: the absolute claim is still reachable, once every row has answered.
        let agreed = facts(copy("/Users/x/Docs/A/r.pdf"), copy("/Users/x/Docs/A/r.pdf"),
                           pages: (left: 12, right: 12))
        #expect(agreed.summary == "Every fact the scan recorded matches.")
    }

    @Test func pageTextPluralizes() {
        #expect(ComparePairFacts.pageText(1) == "1 page")
        #expect(ComparePairFacts.pageText(12) == "12 pages")
        #expect(ComparePairFacts.pageText(0) == "0 pages")
        #expect(ComparePairFacts.pageText(nil) == "…")
    }

    /// No pages argument means the pair is not paged: the row is absent, not present and empty.
    @Test func anUnpagedPairHasNoPageRow() {
        let f = facts(copy("/Users/x/Docs/A/r.txt"), copy("/Users/x/Docs/A/s.txt"))
        #expect(f.rows.contains { $0.field == .pages } == false)
    }

    // MARK: The summary line

    /// Differing names are the premise of a versions group, not a finding, so the name stays a row
    /// and out of the summary.
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

    // MARK: The confirmation's wording

    private static func prompt(_ kind: DuplicateMatchType.Kind) -> String {
        DuplicateComparePrompt.informativeText(
            kind: kind, copyName: "Report (1).pdf", copyLocation: "iCloud › Docs › Old",
            keeperName: "Report.pdf", keeperLocation: "iCloud › Docs", reclaimText: "2.1 MB")
    }

    /// A same-text pair has not been proved redundant, and the last sentence before a delete must
    /// not say it has.
    @Test func aSameTextPairIsNeverCalledRedundant() {
        let text = Self.prompt(.sameText)
        #expect(!text.lowercased().contains("redundant"))
        #expect(text.contains("bytes differ"))
    }

    @Test func anIdenticalPairGetsNoWeakeningClause() {
        let text = Self.prompt(.identical)
        #expect(!text.contains("bytes differ"))
        #expect(text.contains("Reclaims 2.1 MB"))
        #expect(text.contains("⌘Z"))
    }

    /// Trashing a version discards different content; saying so is the difference between a dedup
    /// and a deletion.
    @Test func aVersionsPairSaysTheOtherCopyIsNotACopy() {
        let text = Self.prompt(.versions)
        #expect(text.contains("not copies"))
    }

    /// The budget means something only because the interpolated names are bounded; otherwise it
    /// would measure the data rather than the sentence.
    @Test func everyKindsInformativeLineFitsTheBudget() {
        let longName = String(repeating: "supercalifragilistic", count: 6) + ".pdf"
        for kind in DuplicateMatchType.Kind.allCases {
            let text = DuplicateComparePrompt.informativeText(
                kind: kind, copyName: longName,
                copyLocation: String(repeating: "Folder › ", count: 20),
                keeperName: longName,
                keeperLocation: "iCloud › Docs › Legal › Immigration",
                reclaimText: "2.1 MB")
            #expect(text.count <= DuplicateComparePrompt.lengthBudget,
                    "\(kind) runs \(text.count) characters")
        }
    }

    /// Middle-truncation, because the end of a file name tells two copies apart: "(1)" and the
    /// extension live there.
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

    /// A file at the scan root (an empty location) must not produce "Keeps “x” at . Reclaims…".
    @Test func anEmptyLocationDropsItsClauseRatherThanLeavingAStrandedAt() {
        let text = DuplicateComparePrompt.informativeText(
            kind: .identical, copyName: "Report (1).pdf", copyLocation: "",
            keeperName: "Report.pdf", keeperLocation: "", reclaimText: "2.1 MB")
        #expect(!text.contains(" at ."))
        #expect(text.contains("Trashing “Report (1).pdf”\n\nKeeping “Report.pdf”"),
                "an absent location left a stranded line: \(text)")
    }

    /// The trashed copy and its folder come first: which folder loses the file is the one fact the
    /// confirmation exists to establish, and two copies are often similarly named.
    @Test func theConfirmationNamesTheTrashedCopyAndItsFolderFirst() {
        let text = DuplicateComparePrompt.informativeText(
            kind: .identical,
            copyName: "Lease Agreement.pdf",
            copyLocation: "iCloud › Documents › Vehicles › Honda › Accord › Car Papers › Pilot",
            keeperName: "Car Lease.pdf",
            keeperLocation: "iCloud › Documents › Vehicles › Honda › Pilot › Papers",
            reclaimText: "11.8 MB")
        let trashing = try? #require(text.range(of: "Trashing “Lease Agreement.pdf”"))
        let keeping = try? #require(text.range(of: "Keeping “Car Lease.pdf”"))
        #expect(trashing != nil && keeping != nil)
        if let t = trashing, let k = keeping {
            #expect(t.lowerBound < k.lowerBound, "the survivor was named before the victim")
        }
        #expect(text.contains("Accord › Car Papers › Pilot"),
                "the folder losing the file is not named: \(text)")
        #expect(text.contains("11.8 MB"))
    }

    /// A location too long to print is shortened from the front, so the trailing folders, the
    /// part that differs between two copies, survive.
    @Test func aLongLocationKeepsItsTail() {
        let long = "iCloud › " + (1...20).map { "Folder \($0)" }.joined(separator: " › ")
            + " › The Last One"
        let shortened = DuplicateComparePrompt.location(long)
        #expect(shortened.count <= DuplicateComparePrompt.locationBudget)
        #expect(shortened.hasSuffix("The Last One"), "the distinguishing tail was cut: \(shortened)")
        #expect(shortened.hasPrefix("…"))
        #expect(DuplicateComparePrompt.location("iCloud › Docs") == "iCloud › Docs")
    }

    // MARK: The disabled reason

    /// A greyed button with no reason reads as the app being broken, so a protected copy says why.
    @Test func aProtectedCopySpellsOutWhyItCannotBeTrashed() throws {
        let reason = try #require(DuplicateComparePrompt.disabledReason(copyIsProtected: true,
                                                                       copyName: "Report.pdf"))
        #expect(reason.contains("Report.pdf"))
        #expect(reason.contains("keeping"))
        #expect(DuplicateComparePrompt.disabledReason(copyIsProtected: false,
                                                      copyName: "Report.pdf") == nil)
    }

    // MARK: The trash button's title

    /// The label follows the keeper, not the kind. A versions pair opens keeping the newer
    /// revision, but the reader can flip it, and then the same button trashes the newer copy.
    @Test func flippingTheKeeperRenamesWhatTheButtonDestroys() {
        #expect(DuplicateComparePrompt.trashTitle(kind: .versions, targetIsOlder: true)
                == "Trash the Older Copy")
        #expect(DuplicateComparePrompt.trashTitle(kind: .versions, targetIsOlder: false)
                == "Trash the Newer Copy")
        let older = copy("/x/Notes v1.md", modified: Self.noon)
        let newer = copy("/x/Notes v2.md", modified: Self.noon.addingTimeInterval(86_400))
        #expect(DuplicateComparePrompt.trashTitle(kind: .versions, keeper: newer, target: older)
                == "Trash the Older Copy")
        #expect(DuplicateComparePrompt.trashTitle(kind: .versions, keeper: older, target: newer)
                == "Trash the Newer Copy")
    }

    /// An undated copy, and a pair stamped the same second: neither can be ordered, and the title
    /// says only what it can stand behind.
    @Test func aPairTheDatesCannotOrderIsNamedNeutrally() {
        let dated = copy("/x/a.md", modified: Self.noon)
        let undated = copy("/x/b.md", modified: nil)
        #expect(DuplicateComparePrompt.trashTitle(kind: .versions, keeper: dated, target: undated)
                == "Trash the Other Copy")
        #expect(DuplicateComparePrompt.trashTitle(kind: .versions, keeper: dated,
                                                  target: copy("/x/c.md", modified: Self.noon))
                == "Trash the Other Copy")
    }

    /// A pair with no other copy left (the stale case, verdict disabled) must not crash or claim an age.
    @Test func aMissingTargetIsNamedNeutrally() {
        #expect(DuplicateComparePrompt.trashTitle(kind: .versions,
                                                  keeper: copy("/x/a.md"), target: nil)
                == "Trash the Other Copy")
    }

    /// Age is a versions idea. Identical and same-text copies are the same content twice, so
    /// naming one of them "older" would invite reading age as the reason to destroy it.
    @Test func onlyVersionsPairsTalkAboutAge() {
        for kind in [DuplicateMatchType.Kind.identical, .sameText, .overlapping] {
            for older in [true, false, nil] {
                #expect(DuplicateComparePrompt.trashTitle(kind: kind, targetIsOlder: older)
                        == "Trash the Other Copy")
            }
        }
    }

    // MARK: Where the wording is allowed to live

    /// This package's `Sources/FileExplorer`.
    private static let sourcesDir = SourceText.modules.appendingPathComponent("FileExplorer/Sources/FileExplorer")

    /// The trash button's age words may appear in one source file only, the home of
    /// `DuplicateComparePrompt`, whose tests hold them to the pair's dates. A `switch` in the view
    /// would go on naming the older copy after a flip made it the keeper.
    @Test func onlyThePromptSpellsTheTrashButtonsAgeWords() throws {
        let sources = Self.sourcesDir
        let fm = FileManager.default
        let files = try #require(try? fm.contentsOfDirectory(at: sources,
                                                            includingPropertiesForKeys: nil),
                                 "cannot list \(sources.path) — this scan would be vacuous")
        var offenders: [String] = []
        var found = false
        for url in files where url.pathExtension == "swift" {
            let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                    "cannot read \(url.lastPathComponent)")
            guard text.contains("Trash the Older Copy") || text.contains("Trash the Newer Copy")
            else { continue }
            if url.lastPathComponent == "CompareCopiesModels.swift" { found = true }
            else { offenders.append(url.lastPathComponent) }
        }
        #expect(found, "positive control: CompareCopiesModels.swift no longer spells the titles")
        #expect(offenders.isEmpty, "\(offenders) spell the trash button's age words themselves")
    }
}
