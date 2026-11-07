import Testing
import SwiftUI
@testable import FileExplorer

/// The scans the overview is allowed to offer.
///
/// There are three passes, and the overview offers each once. A `Scan…` per unscanned lens would
/// make "To File" and "Renames" read as separate pieces of work when one walk publishes both, each
/// line true about its lens and the screen describing a machine that doesn't exist.
///
/// These are pure: no render, no manager, no defaults.
@MainActor
@Suite struct OrganizePassTests {

    // MARK: The mapping, from both directions

    /// Every lens that can report has exactly one pass, and the badgeless ones have none. Rules has
    /// no pass for the reason it carries no badge and takes no overview section: it is
    /// configuration, not a result. Giving it a scan means moving all three together, and this says
    /// so.
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

    /// `init(producing:)` is the inverse of `lenses`, over every case. If the two tables drift, a
    /// lens missing from every pass is never offered a scan, which looks exactly like a lens that
    /// has run.
    @Test func producingIsTheInverseOfLenses() {
        for pass in OrganizePass.allCases {
            for lens in pass.lenses {
                #expect(OrganizePass(producing: lens) == pass,
                        "\(lens.title) belongs to \(pass.rawValue) but resolves elsewhere")
            }
        }
        #expect(OrganizePass(producing: .rules) == nil)
    }

    /// A card names only lenses you can go to. Derived from `railItems` rather than written out, so
    /// folding a lens without giving this card a presentation list of its own fails here rather
    /// than on screen. Then the lists as literals, because the number is the claim: the file pass
    /// answers two lenses from one walk, which is the point of the type, and no lens is claimed
    /// twice, or running either pass would silently satisfy both cards.
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

    /// The file card's lede counts the rows underneath it. Asserted against
    /// ``OrganizePass/lenses``, so a change in the row count fails here rather than shipping a card
    /// that miscounts itself.
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

    /// Every pass states a cost, and the file pass's says it is free. The lens this offer leads to
    /// holds the one control in Organize that spends money, and `LensWorkspaceView.refineButton`
    /// says the scan was free and on-device; a card that left the cost unsaid would invite the
    /// opposite assumption.
    @Test func everyPassStatesACostAndTheFilePassIsFree() {
        for pass in OrganizePass.allCases {
            #expect(!pass.offerCost.isEmpty)
            #expect(!pass.runTitle.isEmpty)
            #expect(!pass.offerTitle.isEmpty)
        }
        #expect(OrganizePass.file.offerCost.lowercased().contains("free"))
        #expect(OrganizePass.duplicates.offerCost.lowercased().contains("free"))
    }

    /// The run buttons stand on their own: a button is its own accessibility element, so a label
    /// that only parses beside its heading ("Run it") reads out as nothing useful. Each names its
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

    /// Only a pass answering one lens can be re-run from that lens's row. The file pass answers
    /// two, so a rescan on each row would be two controls running one walk. Its rescan stays on row
    /// 2, where one control speaks for the walk.
    @Test func onlySingleLensPassesCanBeRerunFromARow() {
        #expect(OrganizePass.duplicates.answersOneLens)
        #expect(OrganizePass.folderMemory.answersOneLens)
        #expect(!OrganizePass.file.answersOneLens,
                "the file pass would put an identical Rescan on three rows")
    }

    /// The rule is a property of the pass, not of how much is reporting. "Offer it when this row is
    /// the pass's only reporting voice" would make the button appear and vanish as lenses start and
    /// stop reporting. This varies the data and asks the view which rows carry the control.
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
        // Duplicates reports in every configuration and is the only single-lens pass reporting in
        // any of them, so the answer is the same set each time however many file-pass lenses join.
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

    /// Restructure's refresh is not called a rescan, because it runs no scan: it reads the folder
    /// survey. The verb matches the Rescan menu's for the same action, so the two can't read as two
    /// features.
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

    /// The Rescan menu's item keeps its object, where the card's button drops it: beside "Ignore
    /// saved suggestions" there is no card title to supply the noun, so a bare verb would say
    /// nothing. A source scan, because `Menu` content isn't built until the menu opens.
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

    /// A pass is offered only when running it would change every lens behind it. One flag publishes
    /// both of the file pass's today, so this can't arise yet; asserted anyway, because a card
    /// headed "hasn't run here" over a lens holding an answer would be false.
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

    // MARK: The ledger

    // MARK: A pass is never offered without a way to run it

    /// No card is ever drawn for a pass this host can't start. With no profile, `ContentView`
    /// withholds `onUpdateFolderMemory`, so a never-surveyed machine would otherwise carry a
    /// permanent folder-memory card offering a scan `resurveyFilingMemory` returns early from.
    @Test func noPassIsOfferedWithoutAWayToRunIt() {
        let nothingScanned = OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .notScanned)
        }
        for runnable in [Set<OrganizePass>(), [.file], [.file, .duplicates],
                         Set(OrganizePass.allCases)] {
            let offered = Set(overview(nothingScanned, runnable: runnable).pendingPasses)
            #expect(offered.isSubset(of: runnable),
                    "offered \(offered) with only \(runnable) runnable")
            // A subset assertion passes on an empty set, so it would survive `pendingPasses`
            // breaking entirely. This half proves the offers are still being made.
            #expect(offered == runnable,
                    "with nothing scanned, every runnable pass should be offered: \(offered)")
        }
    }

    /// …and the lens doesn't lose its report as a result: it falls back to the quiet footer line.
    @Test func anUnrunnablePassStillReportsThatItHasNotRun() {
        let subject = overview(OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, $0 == .restructure ? .notScanned : .clean)
        }, runnable: [.file, .duplicates])
        #expect(subject.pendingPasses.isEmpty)
        #expect(subject.strandedUnscanned.map(\.lens) == [.restructure],
                "the unrunnable lens stopped saying it had not run")
    }

    /// One offer per pass, even in the footer: written per row, it could put two identical "Run the
    /// file pass" buttons on two stranded lenses of one walk. This asks
    /// ``OrganizeOverview/offersPassRun(for:)``, the expression the footer branches on.
    ///
    /// With two file-pass lenses, either both are unscanned (the pass is pending and takes a card)
    /// or one has answered (one row strands). Both strand only when the host can't start the pass,
    /// and then the footer must offer nothing, because `offersPassRun` requires runnability. The
    /// at-most-once rule is pinned over every pass by the test below.
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
        // Non-vacuity: the same fixture with the pass runnable offers it, so the emptiness above is
        // the runnability gate and not a fixture that produces no rows at all.
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
        // The fixture has to reach the rule: with `runnable: []`, `offersPassRun` returns false at
        // its guard for every section and `offers.count <= 1` holds at zero by construction.
        //
        // The file pass is the only one that answers two lenses, so the only one that can strand
        // more than one row, and it strands rather than takes a card when some of its lenses have
        // answered. Duplicates and Restructure are left unscanned with their passes runnable, so
        // they take cards and drop out of `strandedUnscanned`.
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
        // `offersPassRun` returning true unconditionally is caught: both file-pass lenses are in
        // the fixture, so the count goes to 2. Replacing `firstStrandedLens(of:) == section.lens`
        // with "is this lens stranded" (the dedupe itself) can't be caught here: two lenses of one
        // pass can't strand while that pass is runnable (both unscanned take a card; not runnable,
        // the guard returns false). The loop states the rule; the two expectations below are the
        // falsifiable part.
        #expect(total == 1,
                "the footer made \(total) run offers — with the file pass half-answered it should make exactly one, and a zero here means the loop above asserted nothing")
        #expect(subject.offersPassRun(for: section(.renames, .notScanned)),
                "the stranded rename lens is the row that carries the file pass's offer")
    }

    /// A stranded lens whose pass this host can't run says so and offers nothing: the quiet line on
    /// its own, as on a machine with no filing profile.
    @Test func aStrandedLensWithNoRunnablePassOffersNothing() {
        let subject = overview([section(.restructure, .notScanned)], runnable: [.file, .duplicates])
        #expect(subject.strandedUnscanned.map(\.lens) == [.restructure])
        #expect(!subject.offersPassRun(for: subject.sections[0]))
    }

    /// A lens that has already answered never draws the footer's run offer, which says "this has
    /// not run"; an answered lens gets the row's own Rescan.
    @Test func anAnsweredLensDrawsNoRunOffer() {
        let answered = section(.duplicates, .findings(count: 3, headline: "3", examples: []))
        #expect(!overview([answered]).offersPassRun(for: answered))
    }

    /// The ledger counts a clean lens as run. Counting only the reporting ones would leave a
    /// fully-scanned clean tree reading "0 of 4 checks have run", contradicting "every check that
    /// has run came back clean" in the line below.
    @Test func aCleanLensCountsAsRun() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: [section(.toFile, .clean),
                   section(.duplicates, .findings(count: 2, headline: "2 groups", examples: [])),
                   section(.renames, .notScanned)],
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == 2)
    }

    /// The denominator is the lenses that can run, four of the six. Counting them all, a fully
    /// checked tree would read "4 of 6" forever, claiming work no button can discharge.
    @Test func theDenominatorExcludesTheLensesThatCannotRun() {
        let ledger = OrganizeOverview.Ledger.derived(from: [],
                                                     runnablePasses: Set(OrganizePass.allCases),
                                                     reclaimable: nil, scopeFolders: nil)
        // Four: two lenses are excluded by the same gate. `countedLenses` keeps only
        // badge-carriers, so Rules (configuration) and Storage (a report with no verb) both stay
        // out of the meter with no ledger code of their own.
        #expect(ledger.checksTotal == 4)
        // Derived from the badge rule, not from arithmetic on `railItems.count`: state the rule and
        // let the count follow it.
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

    /// The ratio closes on a machine that can't run every check. Restructure's pass is the folder
    /// survey, which needs a profile this machine may never have had (`ContentView` withholds the
    /// handler then). Counted anyway, the ledger would read "3 of 4" permanently, against a button
    /// that exists nowhere. The numerator drops the same lens as the denominator.
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

    /// No two things on the overview wear the same glyph. The overview draws the pass cards and the
    /// rail together, so a symbol shared between a pass and an unrelated lens is two meanings for
    /// one picture on one screen.
    @Test func noPassSharesAGlyphWithAnUnrelatedLens() {
        var byGlyph: [String: [String]] = [:]
        for pass in OrganizePass.allCases { byGlyph[pass.symbol, default: []].append("pass.\(pass)") }
        for lens in OrganizeLens.allCases { byGlyph[lens.symbol, default: []].append("lens.\(lens)") }
        #expect(byGlyph.count > 5, "the tables are implausibly small — this scan would be near-vacuous")

        // The one pair that legitimately shares, because one is quoting the other: the duplicate
        // pass card and the Duplicates rail item are the same act. Keep this list exact: a stale
        // entry would let a collision come back unnoticed.
        let quoted: Set<Set<String>> = [
            ["pass.duplicates", "lens.duplicates"],
        ]
        for (glyph, owners) in byGlyph where owners.count > 1 {
            #expect(quoted.contains(Set(owners)),
                    "\(glyph) is worn by \(owners.sorted().joined(separator: " and ")) — one picture, two meanings")
        }
    }

    /// And the quote is a quote: the pass reads the lens rather than restating its glyph. Comparing
    /// the two symbols would compare the model to itself (a hard-coded copy passes too), so this
    /// checks the glyph isn't Rules' and the source reads as a delegation.
    @Test func theDuplicatePassWearsTheDuplicatesLensGlyph() throws {
        #expect(OrganizePass.duplicates.symbol != OrganizeLens.rules.symbol,
                "the duplicate pass card wears the Rules glyph again")
        let source = try SourceText.fileExplorer("OrganizePass.swift")
        #expect(source.contains("case .duplicates: return OrganizeLens.duplicates.symbol"),
                "the pass restates a glyph instead of asking the lens for it")
    }
}
