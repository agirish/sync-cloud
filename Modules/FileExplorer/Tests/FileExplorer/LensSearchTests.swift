import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The per-lens grammars, and above all the rule that shapes them: a lens only declares a token it
/// can actually bind, and its placeholder advertises exactly those.
@Suite struct LensSearchTests {

    // MARK: Organize ▸ To File

    /// The placeholder must never advertise what the parser doesn't recognize — the placeholder
    /// IS the vocabulary lesson, so a token named there that doesn't bind is a lie.
    ///
    /// Asked of `.filing` since the standalone rename lens was retired: the rename backlog and its
    /// to-fix rows are filing-pass output and park in that grammar's slot.
    @Test func filingPlaceholderAdvertisesOnlyBindableTokens() {
        let placeholder = LensSearch.placeholder(for: .filing)
        #expect(placeholder.contains("kind:"))
        #expect(!placeholder.contains("mb"), "Filing can't bind a size token, so it must not offer one")
        #expect(!placeholder.contains(">"))
    }

    // MARK: Organize

    private func suggestion(_ name: String, size: Int = 1000, confidence: FilingConfidence? = .high,
                            destination: String = "/root/Documents/Invoices",
                            reasons: [String] = ["Filename mentions Invoices"]) -> FilingSuggestion {
        let candidates = confidence.map {
            [FilingDestination(path: destination, confidence: $0, reasons: reasons, newSegments: [])]
        } ?? []
        return FilingSuggestion(filePath: "/root/Downloads/\(name)", fileName: name, size: size,
                                modificationDate: nil, candidates: candidates, providerRoot: "/root")
    }

    @Test func organizeBindsKindSizeConfidenceAndDestination() {
        let invoice = suggestion("Invoice Q3.pdf", size: 6_000_000)
        #expect(FilingSearch.parse("kind:pdf").matches(invoice))
        #expect(FilingSearch.parse(">5mb").matches(invoice))
        #expect(!FilingSearch.parse(">10mb").matches(invoice))
        #expect(FilingSearch.parse("<10mb").matches(invoice))
        #expect(FilingSearch.parse("confidence:high").matches(invoice))
        #expect(!FilingSearch.parse("confidence:low").matches(invoice))
        #expect(FilingSearch.parse("to:Invoices").matches(invoice))
        #expect(!FilingSearch.parse("to:Receipts").matches(invoice))
    }

    /// `confidence:` binds to the tier the card SHOWS. A suggestion with no candidate at all
    /// displays under "Needs your pick", so `confidence:low` must find it — keying off the raw
    /// destination confidence would make it unreachable, since it has no destination.
    @Test func organizeConfidenceFollowsTheDisplayedTier() {
        let unsure = suggestion("zxqw9.bin", confidence: nil)
        #expect(FilingConfidenceTier.of(unsure) == .low)
        #expect(FilingSearch.parse("confidence:low").matches(unsure))
        #expect(FilingSearch.parse("confidence:needs").matches(unsure), "the section reads “Needs your pick”")
        #expect(!FilingSearch.parse("confidence:high").matches(unsure))
    }

    /// `to:` matches only the destination being OFFERED. Matching any candidate would surface a
    /// file under `to:Invoices` whose card was plainly offering Receipts.
    @Test func organizeToMatchesOnlyTheOfferedDestination() {
        let offered = FilingDestination(path: "/root/Documents/Receipts", confidence: .high,
                                        reasons: [], newSegments: [])
        let alternate = FilingDestination(path: "/root/Documents/Invoices", confidence: .low,
                                          reasons: [], newSegments: [])
        let item = FilingSuggestion(filePath: "/root/Downloads/x.pdf", fileName: "x.pdf", size: 10,
                                    modificationDate: nil, candidates: [offered, alternate],
                                    providerRoot: "/root")
        #expect(FilingSearch.parse("to:Receipts").matches(item))
        #expect(!FilingSearch.parse("to:Invoices").matches(item), "Invoices is a runner-up, not what the card offers")
    }

    @Test func organizeFreeTextMatchesNameDestinationAndReasons() {
        let item = suggestion("Invoice Q3.pdf", reasons: ["Filename mentions Invoices"])
        #expect(FilingSearch.parse("q3").matches(item))          // file name
        #expect(FilingSearch.parse("documents").matches(item))   // destination path
        #expect(FilingSearch.parse("mentions").matches(item))    // reason
    }

    // MARK: Automations

    private func rule(_ name: String, enabled: Bool = true,
                      conditions: [AutomationCondition] = [.contentContains("invoice")],
                      destination: String = "Documents/Invoices/{year}") -> AutomationRule {
        AutomationRule(name: name, enabled: enabled, conditions: conditions, destinationTemplate: destination)
    }

    @Test func automationsBindEnabledAndDisabled() {
        let on = rule("Invoices")
        let off = rule("Old", enabled: false)
        #expect(AutomationSearch.parse("is:enabled").matches(on))
        #expect(!AutomationSearch.parse("is:enabled").matches(off))
        #expect(AutomationSearch.parse("is:disabled").matches(off))
        #expect(!AutomationSearch.parse("is:disabled").matches(on))
    }

    /// A rule matches a KIND, so `kind:` binds to `FileKind` here — not to an extension. `kind:pdf`
    /// works; `kind:jpg` is not a FileKind and so is plain free text in this lens even though it's
    /// a real token in Duplicates. That asymmetry is the per-lens-honesty rule, and the placeholder
    /// only ever advertises `kind:pdf`.
    @Test func automationsKindBindsToFileKindNotExtension() {
        let pdfRule = rule("Invoices", conditions: [.kindIs(.pdf), .contentContains("invoice")])
        #expect(AutomationSearch.parse("kind:pdf").matches(pdfRule))
        #expect(!AutomationSearch.parse("kind:image").matches(pdfRule))

        let query = AutomationSearch.parse("kind:jpg")
        #expect(query.kind == nil, "jpg is not a FileKind — it can't bind, so it isn't a token here")
        #expect(query.text == "kind:jpg", "and so it falls through to free text verbatim")
        #expect(AutomationSearch.chips("kind:jpg").isEmpty)
    }

    /// The spec expected `rule.summary` alone to carry name + conditions + destination. It does
    /// NOT — `summary` is built from the conditions and the destination and never reads the rule's
    /// name. So a rule NAMED "Invoices" whose conditions mention only "bill" has no "invoice"
    /// anywhere in its summary, and searching `invoice` would silently miss it. Matching name ∪
    /// summary is what delivers the intended "by name, by condition, or by destination".
    @Test func automationsFreeTextFindsRulesByName() {
        let byName = rule("Invoices", conditions: [.contentContains("bill")], destination: "Documents/Paid")
        #expect(!byName.summary.localizedCaseInsensitiveContains("invoice"),
                "guard: if summary ever starts carrying the name, this test's premise is stale")
        #expect(AutomationSearch.parse("invoice").matches(byName), "must still be findable by its name")
    }

    @Test func automationsFreeTextFindsRulesByConditionAndDestination() {
        let item = rule("DetailedBill", conditions: [.contentContains("t-mobile")],
                        destination: "Home/Utilities/T-Mobile/2026")
        #expect(AutomationSearch.parse("t-mobile").matches(item))   // condition AND destination
        #expect(AutomationSearch.parse("utilities").matches(item))  // destination only
        #expect(AutomationSearch.parse("detailed").matches(item))   // name only
        #expect(!AutomationSearch.parse("verizon").matches(item))
    }

    /// Automations has no size token: a rule isn't a file, so there's nothing to weigh.
    @Test func automationsPlaceholderAdvertisesOnlyBindableTokens() {
        let placeholder = LensSearch.placeholder(for: .automations)
        #expect(placeholder.contains("is:enabled"))
        #expect(placeholder.contains("kind:pdf"))
        #expect(!placeholder.contains("mb"))
    }

    // MARK: Storage

    private func entry(_ name: String, bytes: Int, path: String? = nil) -> StorageEntry {
        StorageEntry(path: path ?? "/root/Movies/\(name)", name: name, bytes: bytes, modified: nil)
    }

    @Test func storageBindsKindAndSize() {
        let movie = entry("holiday.mov", bytes: 200_000_000)
        #expect(StorageSearch.parse(">100mb").matches(movie))
        #expect(!StorageSearch.parse(">1gb").matches(movie))
        #expect(StorageSearch.parse("<1gb").matches(movie))
        #expect(StorageSearch.parse("kind:mov").matches(movie))
        #expect(!StorageSearch.parse("kind:pdf").matches(movie))
    }

    @Test func storageFreeTextMatchesNameAndPath() {
        let item = entry("holiday.mov", bytes: 10, path: "/root/Archive/2019/holiday.mov")
        #expect(StorageSearch.parse("holiday").matches(item))
        #expect(StorageSearch.parse("archive").matches(item))
        #expect(!StorageSearch.parse("invoices").matches(item))
    }

    // MARK: Shared vocabulary

    /// `kind:image` must mean the same set of extensions on every surface that offers it — it's
    /// the one class alias, and the whole point of routing through the shared table.
    @Test func kindImageMeansTheSameThingAcrossLenses() {
        #expect(FilingSearch.parse("kind:image").matches(suggestion("photo.png")))
        #expect(StorageSearch.parse("kind:image").matches(entry("photo.jpg", bytes: 1)))
        #expect(!StorageSearch.parse("kind:image").matches(entry("notes.txt", bytes: 1)))
    }

    /// Every lens's ✕ removes the exact word it names, all occurrences — the shared `TokenQuery`
    /// semantics, so a chip can't look dead.
    @Test func chipRemovalStripsTheExactWord() {
        #expect(FilingSearch.removing("to:Invoices >5mb", word: "to:Invoices") == ">5mb")
        #expect(AutomationSearch.removing("is:enabled kind:pdf", word: "is:enabled") == "kind:pdf")
        #expect(StorageSearch.removing(">100mb kind:mov", word: ">100mb") == "kind:mov")
    }

    /// Last-wins dimming within a family, exactly as Duplicates/Compare/Log do it: two `is:` words
    /// mean the last one, and the earlier chip reads as superseded rather than as an active filter.
    ///
    /// Asked of Automations since `RiskyNameSearch` was retired: it carries the same shape of
    /// family — two mutually exclusive `is:` words — which is what the rule is about. The `kind:`
    /// half of the same rule is pinned by `DuplicateSearchTests` and `DifferenceSearchTests`.
    @Test func supersededChipsDimPerFamily() {
        let chips = AutomationSearch.chips("is:enabled is:disabled")
        #expect(chips.count == 2)
        #expect(chips[0].isActive == false)
        #expect(chips[1].isActive == true)
        #expect(AutomationSearch.parse("is:enabled is:disabled").enabled == false, "last wins")
    }
}
