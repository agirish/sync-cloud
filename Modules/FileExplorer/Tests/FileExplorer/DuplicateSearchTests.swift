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

    @Test func kindImageClassMatchesAnyImageExtension() {
        // `kind:image` is a class alias (the "Images" suggestion), matching the fixed extension
        // set — not just JPEGs, which the suggestion used to silently mean.
        let query = DuplicateSearch.parse("kind:image")
        #expect(query.matches(group("photo.jpg", keeperSize: 1)))
        #expect(query.matches(group("photo.PNG", keeperSize: 1)))
        #expect(query.matches(group("photo.heic", keeperSize: 1)))
        #expect(!query.matches(group("notes.pdf", keeperSize: 1)))
        // No extension named "image" would ever match literally — the alias owns the word.
        #expect(!query.matches(group("noext", keeperSize: 1)))
    }

    @Test func exactExtensionMatchingUnchangedByClassAliases() {
        // Everything that isn't an alias stays an exact extension match.
        #expect(DuplicateSearch.parse("kind:jpg").matches(group("photo.jpg", keeperSize: 1)))
        #expect(!DuplicateSearch.parse("kind:jpg").matches(group("photo.png", keeperSize: 1)))
    }

    @Test func duplicateFamilyChipsMarkEarlierOnesInactive() {
        // parse is last-wins within a family; chips must read as the effective query, so the
        // superseded earlier chip renders inactive while both keep their exact raw word for ✕.
        let chips = DuplicateSearch.chips("kind:pdf kind:png >5mb")
        #expect(chips.count == 3)
        #expect(chips[0].raw == "kind:pdf" && chips[0].isActive == false)
        #expect(chips[1].raw == "kind:png" && chips[1].isActive == true)
        #expect(chips[2].isActive == true)
        // The effective query really is the last one.
        #expect(DuplicateSearch.parse("kind:pdf kind:png").kind == "png")

        // Different families never supersede each other.
        #expect(DuplicateSearch.chips(">5mb <10mb").map(\.isActive) == [true, true])
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
