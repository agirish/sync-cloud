import Testing
@testable import Design

/// The reading estimate scales with the count: minutes for a small library, tens of minutes for a
/// middling one, hours for a large one, all from the one measured rate. Organize's survey card and
/// setup's Structure screen both say it through `DocumentSurveyCost`, so each boundary is pinned
/// here in both of its forms.
@Suite struct DocumentSurveyCostTests {

    /// The premise every figure below rests on: 6,140 documents in about three hours.
    @Test func theRateIsTheMeasuredRead() {
        #expect(abs(DocumentSurveyCost.secondsPerDocument - 1.759) < 0.001)
    }

    @Test func underTheThresholdItSaysAFewMinutes() {
        #expect(DocumentSurveyCost.fewMinutesBelow == 200)
        #expect(DocumentSurveyCost.phrase(documents: 12) == "A few minutes for 12 documents.")
        #expect(DocumentSurveyCost.phrase(documents: 1) == "A few minutes for 1 document.")
        #expect(DocumentSurveyCost.phrase(documents: 199) == "A few minutes for 199 documents.")
        #expect(DocumentSurveyCost.offerClause(documents: 199)
                == "A few minutes for 199 documents, in the background.")
    }

    /// 200 documents take minutes, not the three hours 6,140 take: about six, said in the coarse
    /// ten-minute step. A mid-sized library rounds to its own ten minutes.
    @Test func belowAnHourItSaysTensOfMinutes() {
        #expect(DocumentSurveyCost.phrase(documents: 200) == "About 10 min for 200 documents.")
        #expect(DocumentSurveyCost.offerClause(documents: 200)
                == "About 10 min for 200 documents, in the background.")
        #expect(DocumentSurveyCost.phrase(documents: 1_000) == "About 30 min for 1,000 documents.")
        // 1,900 documents are 56 minutes: rounded up to the hour, never "About 60 min".
        #expect(DocumentSurveyCost.phrase(documents: 1_900) == "About 1 h for 1,900 documents.")
    }

    @Test func fromAnHourItSaysWholeHours() {
        #expect(DocumentSurveyCost.phrase(documents: 6_140) == "About 3 h for 6,140 documents.")
        #expect(DocumentSurveyCost.offerClause(documents: 6_140)
                == "About 3 h for 6,140 documents, in the background.")
        #expect(DocumentSurveyCost.phrase(documents: 7_558) == "About 4 h for 7,558 documents.")
        #expect(DocumentSurveyCost.phrase(documents: 1_000_000)
                == "About 489 h for 1,000,000 documents.")
    }
}
