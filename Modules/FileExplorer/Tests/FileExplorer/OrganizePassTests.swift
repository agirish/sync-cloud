import Testing
import SwiftUI
@testable import FileExplorer

/// The scans the overview is allowed to offer: three passes, each offered once. A `Scan…` per
/// unscanned lens would make "To File" and "Renames" read as separate work when one walk publishes
/// both. Pure: no render, no manager, no defaults.
@MainActor
@Suite struct OrganizePassTests {

    // MARK: The mapping, from both directions

/// Every lens that can report has exactly one pass, and the badgeless ones have none. Rules is
/// configuration, not a result: giving it a scan means moving all three together.
    @Test func everyReportingLensHasExactlyOnePassAndRulesHasNone() {
        for lens in OrganizeLens.allCases {
            let passes = OrganizePass.allCases.filter { $0.lenses.contains(lens) }
            if lens.carriesBadge {
                #expect(passes.count == 1,
                        "\(lens.title) is answered by \(passes.count) passes, not exactly one")
            } else {
                #expect(passes.isEmpty, "\(lens.title) scans, and it is meant to be configuration")
            }
        }
    }

/// `init(producing:)` is the inverse of `lenses`, over every case. A lens missing from every pass
/// is never offered a scan, which looks exactly like a lens that has run.
    @Test func producingIsTheInverseOfLenses() {
        for pass in OrganizePass.allCases {
            for lens in pass.lenses {
                #expect(OrganizePass(producing: lens) == pass,
                        "\(lens.title) belongs to \(pass.rawValue) but resolves elsewhere")
            }
        }
        #expect(OrganizePass(producing: .rules) == nil)
    }

/// A card names only lenses you can go to, derived from `railItems`. Then the lists as literals,
/// because the number is the claim: the file pass answers two lenses from one walk, and no lens is
/// claimed twice, or running either pass would satisfy both cards.
    @Test func aPassCardListsOnlyLensesThatHaveAPlaceToGo() {
        for pass in OrganizePass.allCases {
            #expect(pass.lenses.allSatisfy { OrganizeLens.railItems.contains($0) },
                    "\(pass.rawValue) lists a lens the rail does not draw")
        }
        #expect(OrganizePass.file.lenses == [.toFile, .renames])
        #expect(OrganizePass.duplicates.lenses == [.duplicates])
        #expect(OrganizePass.folderMemory.lenses == [.restructure])
    }

    // MARK: The words on the offer

/// The file card's lede counts the rows underneath it, asserted against ``OrganizePass/lenses``.
    @Test func theFileCardLedeCountsTheRows() {
        let lede = OrganizePass.file.offerLede
        let n = OrganizePass.file.lenses.count
        #expect(n == 2,
                "the file card lists \(n) lenses now, and its lede still says “\(lede)” — the counting word has to move with the list")
        #expect(lede.contains("both"), "the file card's lede stopped counting its rows: “\(lede)”")
        #expect(!lede.contains("all three"),
                "the lede counts a third row this card does not draw: “\(lede)”")
        // The other two answer one lens each and draw no rows at all, so neither may count.
        for pass in [OrganizePass.duplicates, .folderMemory] {
            #expect(!pass.offerLede.lowercased().contains("both"))
            #expect(!pass.offerLede.lowercased().contains("all three"))
        }
    }

/// Every pass states a cost, and the file pass's says it is free: its lens holds the one control in
/// Organize that spends money, and an unsaid cost would invite the opposite assumption.
    @Test func everyPassStatesACostAndTheFilePassIsFree() {
        for pass in OrganizePass.allCases {
            #expect(!pass.offerCost.isEmpty)
            #expect(!pass.runTitle.isEmpty)
            #expect(!pass.offerTitle.isEmpty)
        }
        #expect(OrganizePass.file.offerCost.lowercased().contains("free"))
        #expect(OrganizePass.duplicates.offerCost.lowercased().contains("free"))
    }

/// The run buttons stand on their own: a button is its own accessibility element, so each names its
/// pass.
    @Test func runTitlesAreSelfStanding() {
        for pass in OrganizePass.allCases {
            #expect(pass.runTitle.split(separator: " ").count >= 2,
                    "\(pass.rawValue)'s button says “\(pass.runTitle)” — too little on its own")
        }
        #expect(OrganizePass.file.runTitle == "Run the File Pass")
    }

    /// No glyph draws digits beside a count, the rule `OrganizeLens.symbol` follows too:
    /// `textformat.123` renders as a literal "123" next to a number.
    @Test func noPassGlyphDrawsDigits() {
        for pass in OrganizePass.allCases {
            let hasDigit = pass.symbol.contains { $0.isNumber }
            #expect(!hasDigit, "\(pass.rawValue)'s glyph \(pass.symbol) draws digits")
        }
    }

    // MARK: Re-running a pass whose answer is already on screen

/// The rule is a property of the pass, not of how much is reporting, or the button would appear and
/// vanish as lenses start and stop reporting. This varies the data.
    @Test func theRescanRuleDoesNotMoveWithTheData() {
        let configurations: [[OrganizeLens]] = [
            [.duplicates],
            [.duplicates, .toFile],
            [.duplicates, .toFile, .renames],
        ]
        var answers: [Set<OrganizeLens>] = []
        for reporting in configurations {
            let subject = overview(OrganizeLens.allCases.filter(\.carriesBadge).map { lens in
                section(lens, reporting.contains(lens)
                        ? .findings(count: 3, headline: "3", examples: []) : .clean)
            })
            answers.append(Set(subject.sections.filter { subject.offersRescan(for: $0) }.map(\.lens)))
        }
// Duplicates is the only single-lens pass reporting in any configuration, so the answer is the
// same set each time.
        #expect(answers.allSatisfy { $0 == [.duplicates] },
                "which rows offer a rescan moved with the data: \(answers)")
    }

    /// No file-pass lens carries one, however it is arranged: the file pass answers two lenses, and
    /// two buttons running one walk is what this type exists to prevent.
    @Test func aFilePassLensNeverOffersItsOwnRescan() {
        for lens in OrganizePass.file.lenses {
            let subject = overview([section(lens, .findings(count: 3, headline: "3", examples: []))])
            #expect(subject.offersRescan(for: subject.sections[0]) == false,
                    "\(lens.title) offered to re-run the file pass from its own row")
        }
    }

    /// A row already scanning does not offer to start the same scan again.
    @Test func aScanningRowWithdrawsItsRescan() {
        let idle = OrganizeOverviewSection(lens: .duplicates, blurb: "b",
                                           state: .findings(count: 3, headline: "3", examples: []),
                                           isScanning: false)
        let busy = OrganizeOverviewSection(lens: .duplicates, blurb: "b", state: idle.state,
                                           isScanning: true)
        let subject = overview([idle])
        #expect(subject.offersRescan(for: idle))
        #expect(!subject.offersRescan(for: busy))
    }

    /// A lens with no answer yet is offered its pass as a card, never as a row rescan — the two
    /// controls say different things and must not both appear for one lens.
    @Test func anUnansweredRowOffersNoRescan() {
        let subject = overview([section(.duplicates, .notScanned)])
        #expect(!subject.offersRescan(for: subject.sections[0]))
        #expect(subject.pendingPasses == [.duplicates])
    }

    /// A host that cannot run the pass draws no rescan for it either.
    @Test func anUnrunnablePassOffersNoRescan() {
        let answered = section(.duplicates, .findings(count: 3, headline: "3", examples: []))
        #expect(overview([answered], runnable: [.duplicates]).offersRescan(for: answered))
        #expect(!overview([answered], runnable: [.file]).offersRescan(for: answered))
    }

/// Restructure's refresh is not called a rescan: it runs no scan, it reads the folder survey. The
/// verb matches the Rescan menu's for the same action.
    @Test func restructureRefreshesBySurveyingNotScanning() {
        #expect(OrganizePass.folderMemory.rescanTitle == "Refresh")
        #expect(OrganizePass.duplicates.rescanTitle == "Rescan")
    }

    /// The control names its lens to VoiceOver — a bare "Rescan" among five rows says nothing about
    /// which one it belongs to.
    @Test func theRescanControlNamesItsLens() {
        #expect(OrganizePass.duplicates.rescanAccessibilityLabel(for: .duplicates)
                == "Rescan Duplicates")
        // A bare verb, so the lens is appended; a `== "Rescan"` check alone would miss a second
        // short verb.
        #expect(OrganizePass.folderMemory.rescanAccessibilityLabel(for: .restructure)
                == "Refresh Restructure")
    }

/// The Rescan menu's item keeps its object: beside "Ignore saved suggestions" there is no card
/// title to supply the noun. A source scan, because `Menu` content isn't built until it opens.
    @Test func theRescanMenuItemKeepsItsObject() throws {
        let source = try SourceText.fileExplorer("LensWorkspaceView.swift", atLeast: 5000)

        #expect(source.contains("Label(\"Refresh What\u{2019}s Learned\", systemImage: \"brain\")"),
                "the survey item in the Rescan menu no longer names what it refreshes")
        // The typographic apostrophe, matching the two items either side of it.
        #expect(!source.contains("Refresh what's learned"),
                "the menu item uses an ASCII apostrophe")
    }

    // MARK: What the overview offers

    private func section(_ lens: OrganizeLens,
                         _ state: OrganizeOverviewState) -> OrganizeOverviewSection {
        OrganizeOverviewSection(lens: lens, blurb: "blurb", state: state, isScanning: false)
    }

    private func overview(_ sections: [OrganizeOverviewSection],
                          runnable: Set<OrganizePass> = Set(OrganizePass.allCases))
    -> OrganizeOverview {
        OrganizeOverview(sections: sections, scopeLabel: nil, accent: .blue,
                         runnablePasses: runnable, onOpen: { _ in }, onRun: { _ in })
    }

    /// Duplicates and Restructure answered, the file pass never run: one offer, not one per lens.
    @Test func theUnscannedFileLensesProduceOneOffer() {
        let subject = overview([
            section(.toFile, .notScanned),
            section(.duplicates, .findings(count: 722, headline: "722 groups", examples: ["a"])),
            section(.renames, .notScanned),
            section(.restructure, .findings(count: 1, headline: "1 finding", examples: ["b"])),
        ])
        #expect(subject.pendingPasses == [.file])
    }

/// A pass is offered only when running it would change every lens behind it. Unreachable today,
/// but a "hasn't run here" card over a lens holding an answer would be false.
    @Test func aPartlyAnsweredPassIsNotOffered() {
        let subject = overview([
            section(.toFile, .findings(count: 4, headline: "4 files", examples: [])),
            section(.renames, .notScanned),
        ])
        #expect(subject.pendingPasses.isEmpty,
                "the file pass was offered while To File already had an answer")
    }

    /// Nothing scanned at all: every pass is on offer, in a stable order.
    @Test func aFreshTreeOffersEveryPass() {
        let subject = overview(OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .notScanned)
        })
        #expect(subject.pendingPasses == [.file, .duplicates, .folderMemory])
    }

    /// A clean lens is not an offer: collapsing `clean` and `notScanned` would put "hasn't run
    /// here" over a check that ran and came back empty.
    @Test func aCleanLensIsNotOffered() {
        let subject = overview([
            section(.toFile, .clean), section(.renames, .clean),
        ])
        #expect(subject.pendingPasses.isEmpty)
    }

    // MARK: A pass is never offered without a way to run it

/// No card is ever drawn for a pass this host can't start: with no profile, `ContentView` withholds
/// `onUpdateFolderMemory`, and the card would offer a scan that returns early.
    @Test func noPassIsOfferedWithoutAWayToRunIt() {
        let nothingScanned = OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .notScanned)
        }
        for runnable in [Set<OrganizePass>(), [.file], [.file, .duplicates],
                         Set(OrganizePass.allCases)] {
            let offered = Set(overview(nothingScanned, runnable: runnable).pendingPasses)
            #expect(offered.isSubset(of: runnable),
                    "offered \(offered) with only \(runnable) runnable")
// Non-vacuity: a subset assertion passes on an empty set.
            #expect(offered == runnable,
                    "with nothing scanned, every runnable pass should be offered: \(offered)")
        }
    }

    /// …and the lens doesn't lose its report as a result: it falls back to the quiet footer line,
    /// on its own, offering nothing, as on a machine with no filing profile.
    @Test func anUnrunnablePassStillReportsThatItHasNotRun() throws {
        let subject = overview(OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, $0 == .restructure ? .notScanned : .clean)
        }, runnable: [.file, .duplicates])
        #expect(subject.pendingPasses.isEmpty)
        #expect(subject.strandedUnscanned.map(\.lens) == [.restructure],
                "the unrunnable lens stopped saying it had not run")
        let restructure = try #require(subject.sections.first { $0.lens == .restructure })
        #expect(!subject.offersPassRun(for: restructure))
    }

/// One offer per pass, even in the footer, or two stranded lenses of one walk get two identical
/// "Run the file pass" buttons. Asks ``OrganizeOverview/offersPassRun(for:)``. Both file-pass lenses
/// strand only when the host can't start the pass, and then the footer offers nothing.
    @Test func anUnrunnablePassStrandsItsLensesAndOffersNoRun() {
        let subject = overview([section(.toFile, .notScanned),
                                section(.duplicates, .clean),
                                section(.renames, .notScanned)],
                               runnable: [.duplicates, .folderMemory])
        #expect(subject.strandedUnscanned.map(\.lens) == [.toFile, .renames],
                "both file-pass lenses should fall through to the footer when the pass cannot run")
        let offers = subject.sections.filter { subject.offersPassRun(for: $0) }
        #expect(offers.isEmpty,
                "the footer offered to run a pass this host cannot start: \(offers.map(\.lens.title))")
// Non-vacuity: the same fixture with the pass runnable offers it.
        let runnable = overview([section(.toFile, .notScanned),
                                 section(.duplicates, .clean),
                                 section(.renames, .notScanned)])
        #expect(runnable.sections.filter { runnable.offersPassRun(for: $0) }.isEmpty,
                "with the pass runnable these lenses take a CARD, so the footer still offers nothing")
        #expect(runnable.pendingPasses == [.file],
                "the runnable control did not produce the card that replaces the footer offer")
    }

    /// The same rule stated over every pass at once, so a second pass stranding two lenses cannot
    /// slip through a fixture built around the file pass alone.
    @Test func noPassIsEverOfferedTwiceInTheFooter() {
// The fixture has to reach the rule (with `runnable: []` the count is zero by construction). Only
// the file pass can strand more than one row, when some of its lenses have answered; Duplicates
// and Restructure take cards and drop out of `strandedUnscanned`.
        let subject = overview([
            section(.toFile, .findings(count: 12, headline: "12 files", examples: ["a"])),
            section(.renames, .notScanned),
            section(.duplicates, .notScanned),
            section(.restructure, .notScanned),
        ], runnable: Set(OrganizePass.allCases))

        var total = 0
        for pass in OrganizePass.allCases {
            let offers = subject.sections.filter {
                subject.offersPassRun(for: $0) && pass.lenses.contains($0.lens)
            }
            #expect(offers.count <= 1, "\(pass.rawValue) offered \(offers.count) times")
            total += offers.count
        }
// Mutation: `offersPassRun` returning true unconditionally takes the count to 2. The dedupe
// itself can't be caught here, since two lenses of one runnable pass can't strand.
        #expect(total == 1,
                "the footer made \(total) run offers — with the file pass half-answered it should make exactly one, and a zero here means the loop above asserted nothing")
        #expect(subject.offersPassRun(for: section(.renames, .notScanned)),
                "the stranded rename lens is the row that carries the file pass's offer")
    }

    /// A lens that has already answered never draws the footer's run offer, which says "this has
    /// not run"; an answered lens gets the row's own Rescan.
    @Test func anAnsweredLensDrawsNoRunOffer() {
        let answered = section(.duplicates, .findings(count: 3, headline: "3", examples: []))
        #expect(!overview([answered]).offersPassRun(for: answered))
    }

/// The ledger counts a clean lens as run, or a clean tree reads "0 of 4 checks have run" over
/// "every check that has run came back clean".
    @Test func aCleanLensCountsAsRun() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: [section(.toFile, .clean),
                   section(.duplicates, .findings(count: 2, headline: "2 groups", examples: [])),
                   section(.renames, .notScanned)],
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == 2)
    }

/// The denominator is the lenses that can run, four of the six, or a fully checked tree reads
/// "4 of 6" forever.
    @Test func theDenominatorExcludesTheLensesThatCannotRun() {
        let ledger = OrganizeOverview.Ledger.derived(from: [],
                                                     runnablePasses: Set(OrganizePass.allCases),
                                                     reclaimable: nil, scopeFolders: nil)
// Four: `countedLenses` keeps only badge-carriers, so Rules and Storage stay out with no ledger
// code of their own.
        #expect(ledger.checksTotal == 4)
// Derived from the badge rule, not from arithmetic on `railItems.count`.
        #expect(ledger.checksTotal == OrganizeLens.railItems.filter(\.carriesBadge).count)
        #expect(OrganizeLens.railItems.filter { !$0.carriesBadge } == [.rules, .storage],
                "a third lens stopped carrying a badge — it has silently left this denominator too, so decide deliberately whether the meter should still be counting it")
    }

    /// Every lens run, and the ratio closes.
    @Test func aFullyScannedTreeReadsAllOfThem() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: OrganizeLens.allCases.filter(\.carriesBadge).map { section($0, .clean) },
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == ledger.checksTotal)
    }

    /// The strip stays away when it would say nothing: nothing run, no profile, nothing to reclaim.
    /// "0 of 4" over an empty pane is chrome.
    @Test func anUnscannedTreeHasNoLedgerToDraw() {
        let empty = OrganizeOverview.Ledger.derived(
            from: OrganizeLens.allCases.filter(\.carriesBadge).map { section($0, .notScanned) },
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(empty.isEmpty)
        #expect(!OrganizeOverview.Ledger
            .derived(from: [], runnablePasses: Set(OrganizePass.allCases),
                     reclaimable: nil, scopeFolders: 3_013).isEmpty)
    }

/// The ratio closes on a machine that can't run every check: Restructure's survey needs a profile
/// this machine may never have had. The numerator drops the same lens as the denominator.
    @Test func theRatioClosesWhenAPassCannotBeRunHere() {
        let sections = OrganizeLens.railItems.filter(\.carriesBadge).map {
            section($0, $0 == .restructure ? .notScanned : .clean)
        }
        let ledger = OrganizeOverview.Ledger.derived(from: sections,
                                                    runnablePasses: [.file, .duplicates],
                                                    reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksTotal == 3, "Restructure is still in the denominator")
        #expect(ledger.checksRun == 3, "the ratio does not close on a fully-scanned tree")
    }

    /// And an unrunnable lens that has an answer isn't counted as a check either: the numerator and
    /// denominator are taken over one set, so neither can include what the other drops.
    @Test func anUnrunnableLensIsCountedInNeitherHalf() {
        let sections = OrganizeLens.railItems.filter(\.carriesBadge).map { section($0, .clean) }
        let ledger = OrganizeOverview.Ledger.derived(from: sections,
                                                    runnablePasses: [.file, .duplicates],
                                                    reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == 3)
        #expect(ledger.checksTotal == 3)
        #expect(!OrganizeOverview.Ledger.countedLenses(runnablePasses: [.file, .duplicates])
            .contains(.restructure))
    }

    /// Three examples, because the row has the room and one is a sample of size one.
    @Test func theExampleLimitIsThree() {
        #expect(OrganizeOverview.exampleLimit == 3)
    }

/// No two things on the overview wear the same glyph: the pass cards and the rail draw together.
    @Test func noPassSharesAGlyphWithAnUnrelatedLens() {
        var byGlyph: [String: [String]] = [:]
        for pass in OrganizePass.allCases { byGlyph[pass.symbol, default: []].append("pass.\(pass)") }
        for lens in OrganizeLens.allCases { byGlyph[lens.symbol, default: []].append("lens.\(lens)") }
        #expect(byGlyph.count > 5, "the tables are implausibly small — this scan would be near-vacuous")

// The one legitimate pair: the duplicate pass card quotes the Duplicates rail item. Keep this list
// exact, or a collision comes back unnoticed.
        let quoted: Set<Set<String>> = [
            ["pass.duplicates", "lens.duplicates"],
        ]
        for (glyph, owners) in byGlyph where owners.count > 1 {
            #expect(quoted.contains(Set(owners)),
                    "\(glyph) is worn by \(owners.sorted().joined(separator: " and ")) — one picture, two meanings")
        }
    }

/// And the quote is a quote: the pass reads the lens rather than restating its glyph. Comparing
/// the symbols would compare the model to itself, so this checks the source delegates.
    @Test func theDuplicatePassWearsTheDuplicatesLensGlyph() throws {
        #expect(OrganizePass.duplicates.symbol != OrganizeLens.rules.symbol,
                "the duplicate pass card wears the Rules glyph again")
        let source = try SourceText.fileExplorer("OrganizePass.swift")
        #expect(source.contains("case .duplicates: return OrganizeLens.duplicates.symbol"),
                "the pass restates a glyph instead of asking the lens for it")
    }
}
