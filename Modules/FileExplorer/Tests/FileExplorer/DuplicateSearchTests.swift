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

    /// Full-grammar characterization: ONE composite query exercising every token family (`kind:`
    /// twice — the second being the `image` class alias — plus both size comparators), multi-word
    /// free text, and a superseded duplicate-family token — pinning the parsed query fields AND
    /// the chips() output (raw, label, isActive) together. This is the parse↔chips contract that
    /// drifted in round 4 (chips claimed superseded tokens were active while parse ran last-wins,
    /// b9835ab): any change to tokenization, the alias set, last-wins, size parsing, or chip
    /// labeling flips this one block.
    @Test func fullGrammarSnapshotPinsParseAndChipsTogether() {
        let raw = "kind:JPG >500kb <2mb kind:image draft copy"

        // Parse: last kind wins (jpg is superseded), both comparators land in bytes, the free
        // words join in order — and the tokens never leak into the name text.
        let query = DuplicateSearch.parse(raw)
        #expect(query == DuplicateSearch.Query(kind: "image", sizeAtLeast: 500_000,
                                               sizeAtMost: 2_000_000, text: "draft copy"))

        // Chips: every recognized token in typed order, raw preserved verbatim for ✕ removal,
        // sizes formatted the way the app displays them, ONLY the superseded family member
        // inactive.
        #expect(DuplicateSearch.chips(raw) == [
            DuplicateSearch.Chip(raw: "kind:JPG", label: "kind: jpg", isActive: false),
            DuplicateSearch.Chip(raw: ">500kb", label: "> \(FileSyncManager.formatBytes(500_000))", isActive: true),
            DuplicateSearch.Chip(raw: "<2mb", label: "< \(FileSyncManager.formatBytes(2_000_000))", isActive: true),
            DuplicateSearch.Chip(raw: "kind:image", label: "kind: image", isActive: true),
        ])

        // And the effective query behaves as the active chips read: the kind really is the class
        // alias (a PNG matches — the superseded kind:JPG must not still filter), the size bounds
        // apply to the keeper, and the free text still matches the name.
        #expect(query.matches(group("draft copy.png", keeperSize: 1_000_000)))
        #expect(query.matches(group("Draft Copy 2.HEIC", keeperSize: 500_000)))
        #expect(!query.matches(group("draft copy.pdf", keeperSize: 1_000_000)))   // not an image
        #expect(!query.matches(group("draft copy.png", keeperSize: 400_000)))     // below >500kb
        #expect(!query.matches(group("draft copy.png", keeperSize: 3_000_000)))   // above <2mb
        #expect(!query.matches(group("summary.png", keeperSize: 1_000_000)))      // free text fails
    }
}
