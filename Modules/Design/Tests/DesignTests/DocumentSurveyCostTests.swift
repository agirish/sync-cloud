import Testing
@testable import Design

/// **The reading estimate says minutes for a small library and hours for a large one** (FC7).
/// Organize's survey card and setup's Structure screen both say it through `DocumentSurveyCost`,
/// so both sides of the threshold are pinned here, in each of its two forms.
@Suite struct DocumentSurveyCostTests {

    @Test func underTheThresholdItSaysAFewMinutes() {
        #expect(DocumentSurveyCost.fewMinutesBelow == 200)
        #expect(DocumentSurveyCost.phrase(documents: 12) == "A few minutes for 12 documents.")
        #expect(DocumentSurveyCost.phrase(documents: 1) == "A few minutes for 1 document.")
        #expect(DocumentSurveyCost.phrase(documents: 199) == "A few minutes for 199 documents.")
        #expect(DocumentSurveyCost.offerClause(documents: 199)
                == "A few minutes for 199 documents, in the background.")
    }

    @Test func atOrAboveTheThresholdItKeepsTheHours() {
        #expect(DocumentSurveyCost.phrase(documents: 200) == "About 3 h for 200 documents.")
        #expect(DocumentSurveyCost.phrase(documents: 6_140) == "About 3 h for 6,140 documents.")
        #expect(DocumentSurveyCost.offerClause(documents: 200)
                == "About 3 h for 200 documents, in the background.")
    }
}
