import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Coverage for the Tidy ▸ Duplicates token search: `kind:` / size parsing, keeper-size matching,
/// name substring, and backward-compatible free text.
@Suite struct DuplicateSearchTests {

    private func copy(_ name: String, size: Int, keeper: Bool) -> DuplicateCopy {
        DuplicateCopy(id: "/\(name)", name: name, isDirectory: false, size: size, itemCount: 0,
                      modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: keeper)
    }
    private func group(_ name: String, keeperSize: Int) -> DuplicateGroup {
        DuplicateGroup(matchType: .identical, name: name, isDirectory: false,
                       copies: [copy(name, size: keeperSize, keeper: true),
                                copy(name, size: keeperSize, keeper: false)],
                       reclaimableBytes: keeperSize)
    }

    @Test func noTokensPreservesRawText() {
        let query = DuplicateSearch.parse("contract")
        #expect(query.kind == nil && query.sizeAtLeast == nil && query.sizeAtMost == nil)
        #expect(query.text == "contract")
    }

    @Test func parsesKindSizeAndFreeText() {
        let query = DuplicateSearch.parse("kind:PDF >5mb contract")
        #expect(query.kind == "pdf")
        #expect(query.sizeAtLeast == 5_000_000)
        #expect(query.text == "contract")
    }

    @Test func matchesKindOnGroupName() {
        let query = DuplicateSearch.parse("kind:pdf")
        #expect(query.matches(group("contract.pdf", keeperSize: 1)))
        #expect(!query.matches(group("contract.docx", keeperSize: 1)))
    }

    @Test func matchesSizeAgainstTheKeeper() {
        #expect(DuplicateSearch.parse(">5mb").matches(group("a.pdf", keeperSize: 10_000_000)))
        #expect(!DuplicateSearch.parse(">5mb").matches(group("a.pdf", keeperSize: 1_000_000)))
        #expect(DuplicateSearch.parse("<1mb").matches(group("a.pdf", keeperSize: 500_000)))
    }

    @Test func matchesNameSubstringCaseInsensitively() {
        #expect(DuplicateSearch.parse("Contract").matches(group("my-contract.pdf", keeperSize: 1)))
        #expect(!DuplicateSearch.parse("invoice").matches(group("my-contract.pdf", keeperSize: 1)))
    }

    @Test func tokensAndTextCombineWithAnd() {
        let query = DuplicateSearch.parse("kind:pdf contract")
        #expect(query.matches(group("contract.pdf", keeperSize: 1)))
        #expect(!query.matches(group("contract.docx", keeperSize: 1))) // kind fails
        #expect(!query.matches(group("summary.pdf", keeperSize: 1)))   // text fails
    }

    @Test func chipsListKindAndSizeAndSkipNameText() {
        let chips = DuplicateSearch.chips("kind:PDF >5mb contract")
        #expect(chips == [DuplicateSearch.Chip(raw: "kind:PDF", label: "kind: pdf"),
                          DuplicateSearch.Chip(raw: ">5mb", label: "> \(FileSyncManager.formatBytes(5_000_000))")])
    }

    @Test func chipsCoverBothSizeComparators() {
        #expect(DuplicateSearch.chips("<1mb") == [DuplicateSearch.Chip(raw: "<1mb", label: "< \(FileSyncManager.formatBytes(1_000_000))")])
    }

    @Test func chipsAreEmptyWithoutTokens() {
        #expect(DuplicateSearch.chips("contract kind:").isEmpty)
    }

    @Test func removingDropsOnlyTheChipWordVerbatim() {
        #expect(DuplicateSearch.removing("kind:pdf >5mb contract", word: "kind:pdf") == ">5mb contract")
        #expect(DuplicateSearch.removing("kind:pdf >5mb contract", word: ">5mb") == "kind:pdf contract")
    }
}
