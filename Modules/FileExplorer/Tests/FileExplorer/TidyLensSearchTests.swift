import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The four new per-lens grammars, and above all the rule that shapes them: a lens only declares a
/// token it can actually bind, and its placeholder advertises exactly those.
@Suite struct TidyLensSearchTests {

    // MARK: Rename

    private func risky(_ name: String, path: String = "Docs", reason: String = "Contains a colon",
                       isDirectory: Bool = false) -> RiskyName {
        RiskyName(id: "/root/\(path)/\(name)", relativePath: "\(path)/\(name)", currentName: name,
                  sanitizedName: name.replacingOccurrences(of: ":", with: "-"),
                  reason: reason, isDirectory: isDirectory)
    }

    @Test func renameBindsKindAndIsTokens() {
        let pdf = risky("Q3: report.pdf")
        let folder = risky("Trip: 2026", isDirectory: true)
        let image = risky("photo: 1.png")

        #expect(RiskyNameSearch.parse("kind:pdf").matches(pdf))
        #expect(!RiskyNameSearch.parse("kind:pdf").matches(image))
        #expect(RiskyNameSearch.parse("is:folder").matches(folder))
        #expect(!RiskyNameSearch.parse("is:folder").matches(pdf))
        #expect(RiskyNameSearch.parse("is:file").matches(pdf))
        #expect(!RiskyNameSearch.parse("is:file").matches(folder))
    }

    /// A folder has no extension, so `kind:` can never match one. That's the honest answer rather
    /// than a bug: "the PDFs among the risky names" does not include folders.
    @Test func renameKindNeverMatchesAFolder() {
        #expect(!RiskyNameSearch.parse("kind:pdf").matches(risky("Trip: 2026", isDirectory: true)))
    }

    /// THE per-lens-honesty test. `RiskyName` carries no size, so Rename declares no size token —
    /// `>5mb` is not a filter here, it's just text. It must therefore behave as text: no chip is
    /// offered for it, and it searches the name/path/reason like any other word (matching nothing
    /// here). If someone ever adds a size token to this grammar without a size to bind it to, this
    /// is what fails.
    @Test func renameHasNoSizeTokenAtAll() {
        let query = RiskyNameSearch.parse(">5mb")
        #expect(query.text == ">5mb", "an undeclared token must fall through to free text, verbatim")
        #expect(RiskyNameSearch.chips(">5mb").isEmpty, "no chip may be offered for a token that can't bind")
        #expect(!query.matches(risky("Q3: report.pdf")))
    }

    /// And the placeholder must never advertise what the parser doesn't recognize — the placeholder
    /// IS the vocabulary lesson, so a token named there that doesn't bind is a lie.
    @Test func renamePlaceholderAdvertisesOnlyBindableTokens() {
        let placeholder = TidyLensSearch.placeholder(for: .rename)
        #expect(placeholder.contains("kind:"))
        #expect(placeholder.contains("is:folder"))
        #expect(!placeholder.contains("mb"), "Rename can't bind a size token, so it must not offer one")
        #expect(!placeholder.contains(">"))
    }

    @Test func renameFreeTextMatchesNamePathAndReason() {
        let item = risky("Q3: report.pdf", path: "Finance/Archive", reason: "Contains a colon")
        #expect(RiskyNameSearch.parse("report").matches(item))     // current name
        #expect(RiskyNameSearch.parse("finance").matches(item))    // relative path
        #expect(RiskyNameSearch.parse("colon").matches(item))      // reason
        #expect(!RiskyNameSearch.parse("nothing").matches(item))
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
        let placeholder = TidyLensSearch.placeholder(for: .automations)
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
        #expect(RiskyNameSearch.parse("kind:image").matches(risky("photo: 1.heic")))
        #expect(FilingSearch.parse("kind:image").matches(suggestion("photo.png")))
        #expect(StorageSearch.parse("kind:image").matches(entry("photo.jpg", bytes: 1)))
        #expect(!StorageSearch.parse("kind:image").matches(entry("notes.txt", bytes: 1)))
    }

    /// Every lens's ✕ removes the exact word it names, all occurrences — the shared `TokenQuery`
    /// semantics, so a chip can't look dead.
    @Test func chipRemovalStripsTheExactWord() {
        #expect(RiskyNameSearch.removing("kind:pdf is:folder", word: "is:folder") == "kind:pdf")
        #expect(FilingSearch.removing("to:Invoices >5mb", word: "to:Invoices") == ">5mb")
        #expect(AutomationSearch.removing("is:enabled kind:pdf", word: "is:enabled") == "kind:pdf")
        #expect(StorageSearch.removing(">100mb kind:mov", word: ">100mb") == "kind:mov")
    }

    /// Last-wins dimming within a family, exactly as Duplicates/Compare/Log do it: two `is:` words
    /// mean the last one, and the earlier chip reads as superseded rather than as an active filter.
    @Test func supersededChipsDimPerFamily() {
        let chips = RiskyNameSearch.chips("is:folder is:file")
        #expect(chips.count == 2)
        #expect(chips[0].isActive == false)
        #expect(chips[1].isActive == true)
        #expect(RiskyNameSearch.parse("is:folder is:file").isDirectory == false, "last wins")
    }
}
