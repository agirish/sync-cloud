import Foundation
import Testing
@testable import Sync

/// The pure fingerprint rules. Every fixture here is built so that the expected answer differs from
/// what the rule would produce if the rule were removed — a fixture whose expectation equals the
/// fallback cannot fail.
@Suite struct ContentFingerprintTests {

    private func doc(_ text: String, fields: [String] = [], pageCount: Int? = nil,
                     boxes: [String] = ["612x792"]) -> ExtractedDocument {
        ExtractedDocument(pages: [text], formFieldValues: fields,
                          pageCount: pageCount ?? 1, pageBoxes: boxes)
    }

    /// Enough tokens to clear ``ContentFingerprint/minimumTokens`` in every fixture that isn't
    /// about the floor.
    private let body = "Account statement for Abhishek Girish, amount due 124.50 on 2026 03 14, thank you"

    // MARK: The claim it makes

    @Test func twoRendersOfOneDocumentAgreeDespiteDifferentBytes() {
        // The whole feature in one assertion: same text, and the digest says so. The two sides are
        // separate String values, so nothing here can pass by identity.
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
        // Extraction order is what a re-render changes, so the same tokens in another order are
        // the same document. Both fixtures hold the same words — only their order differs — and
        // the tokens are distinct enough that an ordered hash would separate them.
        let forward = doc("alpha bravo charlie delta echo foxtrot golf hotel india")
        let shuffled = doc("india hotel golf foxtrot echo delta charlie bravo alpha")
        #expect(ContentFingerprint.digest(of: forward) == ContentFingerprint.digest(of: shuffled))
    }

    @Test func repetitionCountsSoASetWouldNotDo() {
        // A multiset, not a set. Same distinct tokens on both sides; only how often one repeats
        // differs, which a set-based digest could not see.
        let once = doc("alpha bravo charlie delta echo foxtrot golf hotel india")
        let twice = doc("alpha alpha bravo charlie delta echo foxtrot golf hotel india")
        #expect(ContentFingerprint.digest(of: once) != ContentFingerprint.digest(of: twice))
    }

    // MARK: Ingredients, each pinned separately

    @Test func filledFormFieldsSeparateAFilledFormFromItsBlankTemplate() {
        // The biggest of the precision levers on the real tree: 14 groups of 267 were a filled form
        // beside its own blank, because AcroForm values are not in the page text.
        let blank = doc(body)
        let filled = doc(body, fields: ["applicantName=Aditi"])
        #expect(ContentFingerprint.digest(of: blank) != ContentFingerprint.digest(of: filled))
    }

    @Test func differentFieldValuesInTheSameFormSeparateIt() {
        let aditi = doc(body, fields: ["applicantName=Aditi"])
        let divit = doc(body, fields: ["applicantName=Divit"])
        #expect(ContentFingerprint.digest(of: aditi) != ContentFingerprint.digest(of: divit))
    }

    @Test func pageGeometrySeparatesTwoDocumentsWithTheSameWords() {
        let letter = doc(body, boxes: ["612x792"])
        let a4 = doc(body, boxes: ["595x842"])
        #expect(ContentFingerprint.digest(of: letter) != ContentFingerprint.digest(of: a4))
    }

    @Test func pageCountSeparatesDocumentsThatDifferOnlyBeyondTheReadCap() {
        // The page cap is our own doing, so the hole it opens is ours to close: two documents whose
        // first `maxPagesRead` pages match and which then diverge would otherwise be called the
        // same. This case does not occur on the surveyed tree — the page count removed no group
        // there — so it is pinned here rather than by the corpus.
        let pages = Array(repeating: body, count: ContentFingerprint.maxPagesRead)
        let boxes = Array(repeating: "612x792", count: ContentFingerprint.maxPagesRead)
        let short = ExtractedDocument(pages: pages, pageCount: ContentFingerprint.maxPagesRead,
                                      pageBoxes: boxes)
        let long = ExtractedDocument(pages: pages, pageCount: ContentFingerprint.maxPagesRead + 9,
                                     pageBoxes: boxes)
        #expect(ContentFingerprint.digest(of: short) != ContentFingerprint.digest(of: long))
    }

    @Test func textBeyondTheReadCapIsNotRead() {
        // The other half of the cap: pages past it must not reach the digest, or the cap is not a
        // cap. Same page count on both sides so this cannot pass via the field above.
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
        // What the floor is insurance against, rather than something the tree exhibits: as the
        // text thins, the digest approaches page count + geometry and stops being about the
        // document. These two are DIFFERENT documents of the same shape, and one token between
        // them is not identity. (Measured, the floor removes no group from the real tree — see
        // `ContentFingerprint.minimumTokens`, whose first justification was an extraction race.)
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
        // `FilingSurvey.isDecodable` refuses text like this because glyph soup would become a
        // folder's rarest anchors. Porting that reflex here would have dropped 11 groups measured
        // on the real tree, ten of them real — two downloads of one soupy document produce the
        // SAME soup, which is a perfectly good identity.
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
        // Digests outlive a launch in a cache, so a change to what is hashed must not be able to
        // masquerade as an old answer — the cache would serve entries from the previous rule and
        // silently group under two schemes at once. Asserting `scheme == "pdf-text-1"` alone did
        // NOT catch that: a mutation that dropped the scheme from the hashed string left that
        // assertion passing. A golden over the whole canonical form is what actually holds it, and
        // it fails for ANY change — token rule, separator, ingredient, or scheme — which is the
        // point: each one is a reason to bump the scheme.
        let pinned = ExtractedDocument(pages: ["Account statement, amount due 124.50 on 2026-03-14"],
                                       formFieldValues: ["name=Girish"],
                                       pageCount: 2, pageBoxes: ["612x792"])
        #expect(ContentFingerprint.scheme == "pdf-text-1")
        #expect(ContentFingerprint.digest(of: pinned)
                == "2361501169f662f905cc382b92187b24d9e45f05fc9f932274250e0526b3bbb9")
    }

    @Test func onlyPDFsAreFingerprintable() {
        #expect(ContentFingerprint.canFingerprint(path: "/a/b/Statement.pdf"))
        #expect(ContentFingerprint.canFingerprint(path: "/a/b/STATEMENT.PDF"))
        #expect(!ContentFingerprint.canFingerprint(path: "/a/b/notes.txt"))
        #expect(!ContentFingerprint.canFingerprint(path: "/a/b/scan.jpg"))
    }
}
