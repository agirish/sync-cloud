import Testing
@testable import SyncCloud

/// Coverage for the text→tokens step of the on-device Filing content extractor (F2). The PDF/OCR
/// readers need real files; this pins the NaturalLanguage + category-keyword tokenization that
/// turns extracted text into the tokens the FilingEngine matches on.
@Suite struct ContentSignalExtractorTests {

    @Test func pullsCategoryKeywordsFromDocumentText() {
        let text = "Declarations Page. Your GEICO auto insurance policy for your Tesla Model 3."
        let tokens = ContentSignalExtractor.tokens(fromText: text)
        #expect(tokens.contains("tesla"))      // vehicle brand
        #expect(tokens.contains("insurance"))  // insurance keyword
        #expect(tokens.contains("policy"))
        #expect(tokens.contains("geico"))
    }

    @Test func pullsTaxFormNumbersRaw() {
        let tokens = ContentSignalExtractor.tokens(fromText: "Form 1099-INT — interest income for 2024")
        #expect(tokens.contains("1099"))
    }

    @Test func emptyForContentWithNoSignal() {
        // No entities and no category keywords → nothing to add.
        let tokens = ContentSignalExtractor.tokens(fromText: "lorem ipsum dolor sit amet")
        #expect(tokens.isEmpty)
    }
}
