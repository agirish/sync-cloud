import AppKit
import Design
import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// What changes in a rename, marked. `1. Jan 31 2021.pdf → 01. Jan 31 2021.pdf` has one new
/// character in eighteen, and two whole names leave the reader to find it. Every case below is a
/// rename the pass really makes.
@MainActor
@Suite struct RenameNameDiffTests {

    /// The padded ordinal, the commonest case: one inserted character, nothing removed, and an
    /// empty head because the change is at the very front.
    @Test func aPaddedOrdinalIsOneInsertedCharacter() {
        let parts = RenameNameDiff.parts(current: "1. Jan 31 2021.pdf",
                                         proposed: "01. Jan 31 2021.pdf")
        #expect(parts.prefix == "")
        #expect(parts.removed == "")
        #expect(parts.inserted == "0")
        #expect(parts.suffix == "1. Jan 31 2021.pdf")
        #expect(!parts.isEmpty)
    }

    /// A stripped vendor prefix, the mirror case: something goes, nothing arrives.
    @Test func aStrippedPrefixIsARemovalWithNoInsertion() {
        let parts = RenameNameDiff.parts(current: "9829custbill.pdf", proposed: "custbill.pdf")
        #expect(parts.prefix == "")
        #expect(parts.removed == "9829")
        #expect(parts.inserted == "")
        #expect(parts.suffix == "custbill.pdf")
    }

    /// A middle substitution keeps both shared ends, which keep the marked run small enough to be
    /// worth marking.
    @Test func aMiddleSubstitutionKeepsBothSharedEnds() {
        let parts = RenameNameDiff.parts(current: "Report_final_v2.pdf",
                                         proposed: "Report-final-v2.pdf")
        #expect(parts.prefix == "Report")
        #expect(parts.removed == "_final_")
        #expect(parts.inserted == "-final-")
        #expect(parts.suffix == "v2.pdf")
        // Each side reassembles to the name it came from, so the three runs are safe to render as
        // one string.
        #expect(parts.prefix + parts.removed + parts.suffix == "Report_final_v2.pdf")
        #expect(parts.prefix + parts.inserted + parts.suffix == "Report-final-v2.pdf")
    }

    /// The overlap trap: walking the tail inward without stopping at the head counts a character on
    /// both sides and yields a negative middle. `aa` → `aaa` is the smallest case, and it crashes
    /// rather than misdraws.
    @Test func aRepeatedCharacterDoesNotCountItselfTwice() {
        let grown = RenameNameDiff.parts(current: "aa.pdf", proposed: "aaa.pdf")
        #expect(grown.prefix + grown.removed + grown.suffix == "aa.pdf")
        #expect(grown.prefix + grown.inserted + grown.suffix == "aaa.pdf")
        #expect(grown.inserted == "a")
        #expect(grown.removed == "")

        let shrunk = RenameNameDiff.parts(current: "aaa.pdf", proposed: "aa.pdf")
        #expect(shrunk.prefix + shrunk.removed + shrunk.suffix == "aaa.pdf")
        #expect(shrunk.prefix + shrunk.inserted + shrunk.suffix == "aa.pdf")
    }

    /// Two identical names have nothing to mark. The pass never emits one, and a row that
    /// highlighted an empty run would draw a stray coloured gap.
    @Test func anUnchangedNameMarksNothing() {
        let parts = RenameNameDiff.parts(current: "same.pdf", proposed: "same.pdf")
        #expect(parts.isEmpty)
        #expect(parts.prefix == "same.pdf")
    }

    /// Grapheme clusters, not scalars: splitting inside one would tint half an accent or half a
    /// flag. `Character` comparison is canonical, so a decomposed name off an older disk matches a
    /// composed one.
    @Test func theSplitNeverLandsInsideACharacter() {
        let parts = RenameNameDiff.parts(current: "café 1.pdf", proposed: "café 01.pdf")
        #expect(parts.inserted == "0")
        #expect(parts.prefix + parts.inserted + parts.suffix == "café 01.pdf")

        // The same name spelled decomposed is the same name.
        let decomposed = "cafe\u{0301} 1.pdf"
        #expect(decomposed != "café 1.pdf" || decomposed.unicodeScalars.count
                != "café 1.pdf".unicodeScalars.count)
        let mixed = RenameNameDiff.parts(current: decomposed, proposed: "café 01.pdf")
        #expect(mixed.inserted == "0", "canonical equivalence, not byte equality")
    }

    // MARK: It reaches the pixels

    /// The marked run is drawn, and the two sides mark different things.
    @Test func theChangedRunIsPaintedAndTheTwoSidesDiffer() throws {
        let parts = RenameNameDiff.parts(current: "1. Jan 31 2021.pdf",
                                         proposed: "01. Jan 31 2021.pdf")
        let before = try #require(RestructureRender.raster(
            RenameDiffLabel(parts: parts, showsProposed: false),
            width: 220, height: 22))
        let after = try #require(RestructureRender.raster(
            RenameDiffLabel(parts: parts, showsProposed: true),
            width: 220, height: 22))
        #expect(RestructureRender.inkedPixels(before) > 50, "the name is drawn")
        #expect(RestructureRender.differingPixels(before, after) > 20,
                "the two sides show different text and mark different runs")
    }

    /// The mark itself is drawn, not merely some difference. Both arms show the same string, one
    /// with a middle run to mark and one without, so they draw the same characters at the same
    /// widths and every differing pixel is the mark. Stripping the changed run's colour and weight
    /// must fail it.
    @Test func theChangedRunIsMarkedOnBothSides() throws {
        let real = RenameNameDiff.parts(current: "Report OLDNAME final.pdf",
                                        proposed: "Report NEWNAME final.pdf")
        // `NAME` is shared, so the runs are the three letters before it.
        #expect(real.removed == "OLD" && real.inserted == "NEW",
                "a positive control: this pair really does have a middle run on both sides")

        // Same two strings, marked nowhere.
        let flatCurrent = RenameNameDiff.Parts(prefix: "Report OLDNAME final.pdf", removed: "",
                                               inserted: "", suffix: "")
        let flatProposed = RenameNameDiff.Parts(prefix: "Report NEWNAME final.pdf", removed: "",
                                                inserted: "", suffix: "")

        func raster(_ parts: RenameNameDiff.Parts, proposed: Bool) throws -> NSBitmapImageRep {
            try #require(RestructureRender.raster(
                RenameDiffLabel(parts: parts, showsProposed: proposed),
                width: 260, height: 22))
        }
        let markedCurrent = try raster(real, proposed: false)
        let plainCurrent = try raster(flatCurrent, proposed: false)
        #expect(RestructureRender.inkedPixels(plainCurrent) > 50,
                "a positive control: the unmarked name is drawn")
        #expect(RestructureRender.differingPixels(markedCurrent, plainCurrent) > 30,
                "what goes is marked — same characters, different ink")

        let markedProposed = try raster(real, proposed: true)
        let plainProposed = try raster(flatProposed, proposed: true)
        #expect(RestructureRender.differingPixels(markedProposed, plainProposed) > 30,
                "and so is what arrives")

        // The sides mark in different colours, so a reader tells a loss from a gain without
        // reading either name.
        #expect(RestructureRender.successPixels(markedProposed) > 0,
                "an insertion is green")
        #expect(RestructureRender.successPixels(markedCurrent) == 0,
                "a removal is not")
    }

    /// A name with nothing to mark carries no tint: the marking is the change, not the row.
    @Test func anUnchangedNameCarriesNoTintAtAll() throws {
        let parts = RenameNameDiff.parts(current: "01. report.pdf", proposed: "01. report.pdf")
        let rep = try #require(RestructureRender.raster(
            RenameDiffLabel(parts: parts, showsProposed: true),
            width: 220, height: 22))
        #expect(RestructureRender.inkedPixels(rep) > 50, "a positive control: the name is drawn")
        #expect(RestructureRender.successPixels(rep) == 0)
    }

    // MARK: The banner — what the whole folder has in common

    private static func step(_ current: String, _ proposed: String,
                             reason: String = "Padded to two digits.") -> RenameStep {
        RenameStep(currentPath: "/d/" + current, currentName: current,
                   proposedName: proposed, kind: .tidied, reason: reason)
    }

    /// The shared edit is the banner's whole claim, and holds only when every step makes it: a
    /// banner summarising a folder whose renames differ would be inventing a fact.
    @Test func aUniformPassSharesOneEdit() throws {
        let steps = [Self.step("1. Jan 31 2021.pdf", "01. Jan 31 2021.pdf"),
                     Self.step("2. Feb 15 2021.pdf", "02. Feb 15 2021.pdf"),
                     Self.step("3. Feb 28 2021.pdf", "03. Feb 28 2021.pdf")]
        let edit = try #require(RenamePlanSummary.sharedEdit(steps))
        #expect(edit.removed == "")
        #expect(edit.inserted == "0")
        #expect(edit.atStart)
        #expect(RenamePlanSummary.sharedReason(steps) == "Padded to two digits.")
    }

    /// One step doing something else is enough to withdraw the claim.
    @Test func aMixedPassSharesNothing() {
        let steps = [Self.step("1. Jan 31 2021.pdf", "01. Jan 31 2021.pdf"),
                     Self.step("9829custbill.pdf", "07. Jul 2023.pdf",
                               reason: "Placed into the folder's ordinal grammar.")]
        #expect(RenamePlanSummary.sharedEdit(steps) == nil)
        #expect(RenamePlanSummary.sharedReason(steps) == nil,
                "and with two different reasons the banner states neither")

        // Reasons are independent of edits: one edit for two stated reasons shows the pattern
        // with no sentence rather than picking one.
        let oneEditTwoReasons = [Self.step("1. a.pdf", "01. a.pdf", reason: "Padded."),
                                 Self.step("2. b.pdf", "02. b.pdf", reason: "Renumbered.")]
        #expect(RenamePlanSummary.sharedEdit(oneEditTwoReasons) != nil)
        #expect(RenamePlanSummary.sharedReason(oneEditTwoReasons) == nil)
    }

    /// Position is part of the edit: inserting `0` at the front and before the extension are
    /// different changes, and one pattern for both would say nothing about where it applies.
    @Test func thesamRunAtADifferentPlaceIsADifferentEdit() {
        let steps = [Self.step("1. report.pdf", "01. report.pdf"),
                     Self.step("report 1.pdf", "report 01.pdf")]
        let edit = RenamePlanSummary.sharedEdit(steps)
        // The runs match, so the guard that saves this is `atStart` disagreeing across them.
        #expect(edit?.atStart != true, "a pattern is only offered where every edit is at the front")
    }

    /// Reasons that agree are stated once; reasons that differ are left on their rows.
    @Test func onlyAnAgreedReasonIsLiftedIntoTheBanner() {
        let same = [Self.step("1. a.pdf", "01. a.pdf", reason: "Padded."),
                    Self.step("2. b.pdf", "02. b.pdf", reason: "Padded.")]
        #expect(RenamePlanSummary.sharedReason(same) == "Padded.")

        let different = [Self.step("1. a.pdf", "01. a.pdf", reason: "Padded."),
                         Self.step("2. b.pdf", "02. b.pdf", reason: "Renumbered.")]
        #expect(RenamePlanSummary.sharedReason(different) == nil)
        #expect(RenamePlanSummary.sharedReason([]) == nil)
    }

    /// The pattern is built from a real name in the folder, with a little of the shared tail so the
    /// reader sees where the edit lands.
    @Test func thePatternComesFromARealNameAndShowsWhereItLands() throws {
        let steps = [Self.step("1. Jan 31 2021.pdf", "01. Jan 31 2021.pdf")]
        let edit = try #require(RenamePlanSummary.sharedEdit(steps))
        let pattern = try #require(RenamePlanSummary.pattern(for: edit, sample: steps[0]))
        #expect(pattern.before == "1. ")
        #expect(pattern.after == "01. ")

        // An edit not at the start gets no pattern: the fragments alone wouldn't say which part of
        // the name they're about.
        let midway = RenamePlanSummary.SharedEdit(removed: "_", inserted: "-", atStart: false)
        #expect(RenamePlanSummary.pattern(for: midway, sample: steps[0]) == nil)
    }

    // MARK: The two columns

    /// The table as a card holds it: pinned to the leading edge, free to fill. The tests below
    /// check that the columns divide the card rather than fit the names, or the After column would
    /// start at a different x on every card. Widening the card moves an even split's edge to the
    /// new midpoint, and the "After" heading and inserted runs are the only green, so the leftmost
    /// success pixel is that edge.
    ///
    /// `RestructureRender.raster` centres what it draws, which matters once the cap stops the
    /// table: a capped 600pt table centred in a 1,200pt frame has its midpoint where an uncapped
    /// one would.
    private static func leading(_ table: RenameColumnsTable) -> some View {
        HStack(spacing: 0) { table; Spacer(minLength: 0) }
    }

    @Test func theAfterColumnStartsAtTheMidpointAtEveryWidth() throws {
        let steps = [Self.step("1. Jan 31 2021.pdf", "01. Jan 31 2021.pdf"),
                     Self.step("2. Feb 15 2021.pdf", "02. Feb 15 2021.pdf")]
        let table = Self.leading(RenameColumnsTable(steps: steps))

        for width in [320.0, 520.0] as [CGFloat] {
            let rep = try #require(RestructureRender.raster(table, width: width, height: 60))
            #expect(RestructureRender.inkedPixels(rep) > 100,
                    "a positive control: the table is drawn at \(width)pt")
            let edge = try #require(RestructureRender.leftmostSuccessFraction(rep),
                                    "the After column is tinted, so it can be located")
            // Half the width, give or take the grid's gutter. Content-sized columns (the frames
            // removed) put it at 0.27 of 520pt.
            #expect(abs(edge - 0.5) < 0.08, "at \(width)pt the After column began at \(edge)")
        }
    }

    /// The cap: past ``RenameColumnsTable/namesMeasure`` the table stops growing, so a card alone on
    /// a wide pane keeps its two columns a glance apart instead of a window apart.
    @Test func aVeryWideCardStopsSpreadingItsColumns() throws {
        let steps = [Self.step("1. Jan 31 2021.pdf", "01. Jan 31 2021.pdf")]
        let width = RenameColumnsTable.namesMeasure * 2
        let rep = try #require(RestructureRender.raster(
            Self.leading(RenameColumnsTable(steps: steps)),
            width: width, height: 44))
        let edge = try #require(RestructureRender.leftmostSuccessFraction(rep))
        // Half the capped measure, as a fraction of the doubled frame: a quarter, not a half.
        #expect(abs(edge - 0.25) < 0.08, "the columns spread to \(edge) of a \(width)pt frame")
    }
}
