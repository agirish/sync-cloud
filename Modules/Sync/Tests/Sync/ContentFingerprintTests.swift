import Foundation
import Testing
@testable import Sync

/// The pure fingerprint rules. Each fixture's expected answer differs from what the code would give
/// without the rule, since a fixture whose expectation equals the fallback can't fail.
@Suite struct ContentFingerprintTests {

    private func doc(_ text: String, fields: [String] = [], pageCount: Int? = nil,
                     boxes: [String] = ["612x792"]) -> ExtractedDocument {
        ExtractedDocument(pages: [text], formFieldValues: fields,
                          pageCount: pageCount ?? 1, pageBoxes: boxes)
    }

    /// Enough tokens to clear ``ContentFingerprint/minimumTokens`` in every fixture that isn't
    /// about the floor.
    private let body = "Account statement for Father Elder, amount due 124.50 on 2026 03 14, thank you"

    // MARK: The claim it makes

    @Test func twoRendersOfOneDocumentAgreeDespiteDifferentBytes() {
        // Same text, same digest. The two sides are separate String values, so this can't pass by
        // identity.
        let a = doc(body)
        let b = doc(String(body.reversed().reversed()))
        #expect(ContentFingerprint.digest(of: a) != nil)
        #expect(ContentFingerprint.digest(of: a) == ContentFingerprint.digest(of: b))
    }

    @Test func differentTextGivesDifferentDigests() {
        #expect(ContentFingerprint.digest(of: doc(body))
                != ContentFingerprint.digest(of: doc(body + " revised")))
    }

    @Test func theDigestIsOverTheSORTEDMultiset() {
        // A re-render changes extraction order, so the same tokens in another order are the same
        // document. The tokens are distinct enough that an ordered hash would separate them.
        let forward = doc("alpha bravo charlie delta echo foxtrot golf hotel india")
        let shuffled = doc("india hotel golf foxtrot echo delta charlie bravo alpha")
        #expect(ContentFingerprint.digest(of: forward) == ContentFingerprint.digest(of: shuffled))
    }

    @Test func repetitionCountsSoASetWouldNotDo() {
        // A multiset, not a set: only how often one token repeats differs, which a set can't see.
        let once = doc("alpha bravo charlie delta echo foxtrot golf hotel india")
        let twice = doc("alpha alpha bravo charlie delta echo foxtrot golf hotel india")
        #expect(ContentFingerprint.digest(of: once) != ContentFingerprint.digest(of: twice))
    }

    // MARK: Ingredients, each pinned separately

    @Test func filledFormFieldsSeparateAFilledFormFromItsBlankTemplate() {
        // The biggest precision lever on a real tree: AcroForm values aren't in the page text, so
        // without them a filled form matches its own blank.
        let blank = doc(body)
        let filled = doc(body, fields: ["applicantName=Daughter"])
        #expect(ContentFingerprint.digest(of: blank) != ContentFingerprint.digest(of: filled))
    }

    @Test func differentFieldValuesInTheSameFormSeparateIt() {
        let daughter = doc(body, fields: ["applicantName=Daughter"])
        let son = doc(body, fields: ["applicantName=Son"])
        #expect(ContentFingerprint.digest(of: daughter) != ContentFingerprint.digest(of: son))
    }

    @Test func pageGeometrySeparatesTwoDocumentsWithTheSameWords() {
        let letter = doc(body, boxes: ["612x792"])
        let a4 = doc(body, boxes: ["595x842"])
        #expect(ContentFingerprint.digest(of: letter) != ContentFingerprint.digest(of: a4))
    }

    @Test func pageCountSeparatesDocumentsThatDifferOnlyBeyondTheReadCap() {
        // The page cap opens a hole the page count closes: two documents whose first
        // `maxPagesRead` pages match and then diverge would otherwise be called the same. The
        // corpus has no such pair, so it is pinned here.
        let pages = Array(repeating: body, count: ContentFingerprint.maxPagesRead)
        let boxes = Array(repeating: "612x792", count: ContentFingerprint.maxPagesRead)
        let short = ExtractedDocument(pages: pages, pageCount: ContentFingerprint.maxPagesRead,
                                      pageBoxes: boxes)
        let long = ExtractedDocument(pages: pages, pageCount: ContentFingerprint.maxPagesRead + 9,
                                     pageBoxes: boxes)
        #expect(ContentFingerprint.digest(of: short) != ContentFingerprint.digest(of: long))
    }

    @Test func textBeyondTheReadCapIsNotRead() {
        // Pages past the cap must not reach the digest. Same page count on both sides, so this
        // can't pass through the page count.
        let head = Array(repeating: body, count: ContentFingerprint.maxPagesRead)
        let boxes = Array(repeating: "612x792", count: ContentFingerprint.maxPagesRead)
        let plain = ExtractedDocument(pages: head + ["nothing here"], pageCount: 30, pageBoxes: boxes)
        let extra = ExtractedDocument(pages: head + ["a wholly different twenty-first page"],
                                      pageCount: 30, pageBoxes: boxes)
        #expect(ContentFingerprint.digest(of: plain) == ContentFingerprint.digest(of: extra))
    }

    // MARK: The floor

    @Test func aDocumentThatSaysTooLittleGetsNoFingerprint() {
        let thin = doc("recorded county of contra costa state of")
        #expect(ContentFingerprint.tokens(in: "recorded county of contra costa state of").count
                == ContentFingerprint.minimumTokens - 1)
        #expect(ContentFingerprint.digest(of: thin) == nil)
    }

    @Test func textlessScansOfTheSameShapeAreNotOneDocument() {
        // What the floor insures against: as the text thins, the digest approaches page count plus
        // geometry and stops being about the document. These are different documents of one shape,
        // and one token between them is not identity. See `ContentFingerprint.minimumTokens`.
        let boxes = ["612x792", "612x792"]
        let q1 = ExtractedDocument(pages: ["1", ""], pageCount: 2, pageBoxes: boxes)
        let q4 = ExtractedDocument(pages: ["1", ""], pageCount: 2, pageBoxes: boxes)
        #expect(ContentFingerprint.digest(of: q1) == nil)
        #expect(ContentFingerprint.digest(of: q4) == nil)
    }

    @Test func exactlyTheFloorIsEnough() {
        let atFloor = doc("recorded county of contra costa state of california")
        #expect(ContentFingerprint.tokens(in: "recorded county of contra costa state of california").count
                == ContentFingerprint.minimumTokens)
        #expect(ContentFingerprint.digest(of: atFloor) != nil)
    }

    @Test func aDocumentWithNoTextAtAllGetsNoFingerprint() {
        #expect(ContentFingerprint.digest(of: doc("")) == nil)
        #expect(ContentFingerprint.digest(of: ExtractedDocument(pages: [], pageCount: 3)) == nil)
    }

    @Test func formFieldValuesCountTowardTheFloor() {
        // A one-word page with a filled form is still a document that said something.
        let mostlyFields = ExtractedDocument(
            pages: ["Form"],
            formFieldValues: ["a=one", "b=two", "c=three", "d=four", "e=five", "f=six", "g=seven"],
            pageCount: 1, pageBoxes: ["612x792"])
        #expect(ContentFingerprint.digest(of: mostlyFields) != nil)
    }

    // MARK: Glyph soup is identity, not noise

    @Test func undecodableGlyphSoupStillFingerprints() {
        // `FilingSurvey.isDecodable` refuses text like this, since glyph soup would become a
        // folder's rarest anchors. Here it stays: two downloads of one soupy document produce the
        // same soup, which is a good identity, and refusing it drops real groups.
        let soup = "d9 lm g8 a1 zz q4 kk p2 vv nn"
        #expect(FilingSurvey.isDecodable(soup) == false)
        #expect(ContentFingerprint.digest(of: doc(soup)) != nil)
        #expect(ContentFingerprint.digest(of: doc(soup)) == ContentFingerprint.digest(of: doc(soup)))
    }

    // MARK: Tokenizer

    @Test func tokensAreMaximalAsciiAlphanumericRunsLowercased() {
        #expect(ContentFingerprint.tokens(in: "Acct #5QU-52593, due $1,240.50")
                == ["acct", "5qu", "52593", "due", "1", "240", "50"])
    }

    @Test func theFingerprintTokenizerKeepsWhatTheRouterThrowsAway() {
        // Deliberately not `FilingRouter.tokenize`: that one drops stop words and single
        // characters because it scores relevance. Identity needs every character.
        #expect(ContentFingerprint.tokens(in: "the a b") == ["the", "a", "b"])
        #expect(FilingRouter.tokenize("the a b").isEmpty)
    }

    // MARK: Scheme

    @Test func theCanonicalFormIsPinnedByAGoldenDigest() {
        // Digests outlive a launch in a cache, so a change to what is hashed must not pass as an old
        // answer, or the cache groups under two schemes at once. Asserting the scheme name alone
        // misses dropping the scheme from the hashed string; a golden over the whole canonical form
        // fails for any change (token rule, separator, ingredient, scheme), each a reason to bump it.
        let pinned = ExtractedDocument(pages: ["Account statement, amount due 124.50 on 2026-03-14"],
                                       formFieldValues: ["name=Elder"],
                                       pageCount: 2, pageBoxes: ["612x792"])
        #expect(ContentFingerprint.scheme == "pdf-text-1")
        // A change to this golden needs a new scheme, unless only the pinned input changed.
        #expect(ContentFingerprint.digest(of: pinned)
                == "c43767b9557d1ec98400468d5b000ed15c1275f630691c656e4a82a525a1becf")
    }

    @Test func onlyPDFsAreFingerprintable() {
        #expect(ContentFingerprint.canFingerprint(path: "/a/b/Statement.pdf"))
        #expect(ContentFingerprint.canFingerprint(path: "/a/b/STATEMENT.PDF"))
        #expect(!ContentFingerprint.canFingerprint(path: "/a/b/notes.txt"))
        #expect(!ContentFingerprint.canFingerprint(path: "/a/b/scan.jpg"))
    }
}
