import Testing
import SwiftUI
@testable import FileExplorer

/// The scans the overview is allowed to offer.
///
/// **The screen this replaces offered five and there are three**, which is the defect worth
/// pinning: its footer drew a `Scan…` per unscanned lens, so "To File", "Names" and "Renames" read
/// as three pieces of work you could pick between when one walk publishes all three. Nothing in the
/// old code was wrong about any single line — each said something true about its own lens — and the
/// screen as a whole described a machine that does not exist.
///
/// These are pure: no render, no manager, no defaults.
@MainActor
@Suite struct OrganizePassTests {

    // MARK: The mapping, from both directions

    /// Every lens that can report has a pass, and Rules does not.
    ///
    /// The `carriesBadge` pairing is the load-bearing half. Rules is excluded from passes for the
    /// same reason it carries no badge and takes no overview section — it is configuration, not a
    /// result — so if a later change gives it a scan, three places have to move together and this
    /// is the one that says so.
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

    /// `init(producing:)` is the inverse of `lenses`, over every case.
    ///
    /// Two tables that must agree, asserted rather than assumed — the failure mode if they drift is
    /// silent: a lens missing from every pass simply never gets offered a scan, which on screen
    /// looks exactly like a lens that has already run.
    @Test func producingIsTheInverseOfLenses() {
        for pass in OrganizePass.allCases {
            for lens in pass.lenses {
                #expect(OrganizePass(producing: lens) == pass,
                        "\(lens.title) belongs to \(pass.rawValue) but resolves elsewhere")
            }
        }
        #expect(OrganizePass(producing: .rules) == nil)
    }

    /// The file pass answers **three** lenses, and that is the whole point of the type.
    ///
    /// Pinned as a literal rather than derived, because the number is the claim: `FileSyncManager`
    /// publishes the filing queue, the risky names and the rename backlog from one walk, and an
    /// offer that promised fewer would be the old footer's mistake told the other way round.
    @Test func theFilePassAnswersAllThreeOfItsLenses() {
        #expect(OrganizePass.file.lenses == [.toFile, .names, .renames])
        #expect(OrganizePass.duplicates.lenses == [.duplicates])
        #expect(OrganizePass.folderMemory.lenses == [.restructure])
    }

    /// No lens is claimed by two passes — otherwise the overview would draw two offers for one
    /// answer, and running either would silently satisfy both cards.
    @Test func noLensIsClaimedByTwoPasses() {
        var seen: Set<OrganizeLens> = []
        for pass in OrganizePass.allCases {
            for lens in pass.lenses {
                #expect(seen.insert(lens).inserted, "\(lens.title) is claimed by two passes")
            }
        }
    }

    /// A card names only lenses you can go to — so the folded Names lens is not one of them.
    ///
    /// The walk still answers Names, which is why ``OrganizePass/lenses`` still lists it and the
    /// test above pins that. What a *card row* claims is different: it promises a place the answer
    /// lands, and Names has none — no rail item (`OrganizeLens.railItems` omits it), no overview
    /// section (`overviewSections` returns `nil` for it), and its findings already promised by the
    /// Renames row directly beside it. The file card listed all three and so offered one
    /// destination twice under two names.
    ///
    /// Derived from `railItems` rather than written out, because the fold has exactly one
    /// definition and a second literal here is how the screen drifts back.
    @Test func aPassCardListsOnlyLensesThatHaveAPlaceToGo() {
        for pass in OrganizePass.allCases {
            #expect(pass.presentedLenses.allSatisfy { OrganizeLens.railItems.contains($0) },
                    "\(pass.rawValue) would list a lens the rail does not draw")
            #expect(pass.presentedLenses == pass.lenses.filter { !$0.isFoldedIntoRenames })
        }
        #expect(OrganizePass.file.presentedLenses == [.toFile, .renames],
                "the file card is back to naming the folded Names lens as a row of its own")
        // The fold removes a row and nothing else: every pass still answers what it answered.
        #expect(OrganizePass.duplicates.presentedLenses == [.duplicates])
        #expect(OrganizePass.folderMemory.presentedLenses == [.restructure])
    }

    // MARK: The words on the offer

    /// **The file card's lede counts the rows underneath it**, and this is what keeps the two
    /// honest.
    ///
    /// It read "One walk of the tree answers all three" while the card had already stopped drawing
    /// three rows — the sentence went on asserting the shape of a list that had changed under it,
    /// which is the exact failure a literal count invites. Asserted against
    /// ``OrganizePass/presentedLenses`` so a third row (or a first fold) fails here rather than
    /// shipping a card that miscounts itself.
    @Test func theFileCardLedeCountsTheRows() {
        let lede = OrganizePass.file.offerLede
        let n = OrganizePass.file.presentedLenses.count
        #expect(n == 2,
                "the file card lists \(n) lenses now, and its lede still says “\(lede)” — the counting word has to move with the list")
        #expect(lede.contains("both"), "the file card's lede stopped counting its rows: “\(lede)”")
        #expect(!lede.contains("all three"),
                "the lede counts the folded Names row again: “\(lede)”")
        // The other two answer one lens each and draw no rows at all, so neither may count.
        for pass in [OrganizePass.duplicates, .folderMemory] {
            #expect(!pass.offerLede.lowercased().contains("both"))
            #expect(!pass.offerLede.lowercased().contains("all three"))
        }
    }

    /// Every pass states a cost, and the file pass's says it is free.
    ///
    /// **Not decoration.** The lens this offer leads to contains the one control in Organize that
    /// spends money, and `LensWorkspaceView.refineButton` is explicit that "the scan that produced these
    /// rows was free and on-device". A card that left the cost unsaid invites the opposite
    /// assumption about the button directly above it.
    @Test func everyPassStatesACostAndTheFilePassIsFree() {
        for pass in OrganizePass.allCases {
            #expect(!pass.offerCost.isEmpty)
            #expect(!pass.runTitle.isEmpty)
            #expect(!pass.offerTitle.isEmpty)
        }
        #expect(OrganizePass.file.offerCost.lowercased().contains("free"))
        #expect(OrganizePass.duplicates.offerCost.lowercased().contains("free"))
    }

    /// The run buttons stand on their own.
    ///
    /// A button is its own accessibility element, so a label that only parses beside the heading
    /// above it ("Run it") is read out as nothing useful. Each names its pass.
    @Test func runTitlesAreSelfStanding() {
        for pass in OrganizePass.allCases {
            #expect(pass.runTitle.split(separator: " ").count >= 2,
                    "\(pass.rawValue)'s button says “\(pass.runTitle)” — too little on its own")
        }
        #expect(OrganizePass.file.runTitle == "Run the file pass")
    }

    /// No glyph draws digits beside a count — the same deny-list `OrganizeLens.symbol` carries,
    /// which caught `textformat.123` rendering as the literal "123" next to a number.
    @Test func noPassGlyphDrawsDigits() {
        for pass in OrganizePass.allCases {
            let hasDigit = pass.symbol.contains { $0.isNumber }
            #expect(!hasDigit, "\(pass.rawValue)'s glyph \(pass.symbol) draws digits")
        }
    }

    // MARK: Re-running a pass whose answer is already on screen

    /// Only a pass answering **one** lens can be re-run from that lens's row.
    ///
    /// The file pass answers three, so a rescan on each of their rows would be three controls
    /// running one identical walk — the defect this whole type exists to remove, rebuilt on the
    /// other side of the screen. Its rescan stays on row 2, where one control speaks for the walk.
    @Test func onlySingleLensPassesCanBeRerunFromARow() {
        #expect(OrganizePass.duplicates.answersOneLens)
        #expect(OrganizePass.folderMemory.answersOneLens)
        #expect(!OrganizePass.file.answersOneLens,
                "the file pass would put an identical Rescan on three rows")
    }

    /// The rule is a property of the **pass**, not of how much happens to be reporting.
    ///
    /// The permissive alternative — "offer it when this row is the pass's only reporting voice" —
    /// makes the button appear and vanish as lenses start and stop reporting, so which control sits
    /// under the cursor depends on the tree's contents.
    ///
    /// **The first version of this test was vacuous** and review caught it: it bound a loop
    /// variable of reporting sets, discarded it with `_ =`, and then asserted `answersOneLens`
    /// three times over. It compared the model to itself and would have passed against the
    /// permissive rule it exists to reject. This one varies the data and asks the view which rows
    /// actually carry the control.
    @Test func theRescanRuleDoesNotMoveWithTheData() {
        let configurations: [[OrganizeLens]] = [
            [.duplicates],
            [.duplicates, .toFile],
            [.duplicates, .toFile, .names],
            [.duplicates, .toFile, .names, .renames],
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

    /// To File never carries one however it is arranged — the file pass answers three lenses, and
    /// three buttons running one walk is the defect this whole type removes.
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

    /// A lens with no answer yet is offered its pass as a **card**, never as a row rescan — the two
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

    /// Restructure's refresh is **not** called a rescan, because it runs no scan.
    ///
    /// It reads the folder survey; the honest verb is the survey's own, and it is the same wording
    /// the Rescan menu already uses for the same action so the two cannot read as two features.
    @Test func restructureRefreshesBySurveyingNotScanning() {
        #expect(OrganizePass.folderMemory.rescanTitle == "Update folder memory")
        #expect(OrganizePass.duplicates.rescanTitle == "Rescan")
    }

    /// The control names its lens to VoiceOver — a bare "Rescan" among five rows says nothing about
    /// which one it belongs to.
    @Test func theRescanControlNamesItsLens() {
        #expect(OrganizePass.duplicates.rescanAccessibilityLabel(for: .duplicates)
                == "Rescan Duplicates")
        // Already self-standing, so it is not padded into "Update folder memory Restructure".
        #expect(OrganizePass.folderMemory.rescanAccessibilityLabel(for: .restructure)
                == "Update folder memory")
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

    /// The screenshot's state: duplicates and restructure answered, the file pass never run.
    /// **One offer, not three.**
    @Test func theThreeUnscannedFileLensesProduceOneOffer() {
        let subject = overview([
            section(.toFile, .notScanned),
            section(.duplicates, .findings(count: 722, headline: "722 groups", examples: ["a"])),
            section(.names, .notScanned),
            section(.renames, .notScanned),
            section(.restructure, .findings(count: 1, headline: "1 finding", examples: ["b"])),
        ])
        #expect(subject.pendingPasses == [.file])
    }

    /// A pass is offered only when running it would change **every** lens behind it.
    ///
    /// The `allSatisfy` half of the rule, and the direction that cannot arise today: one flag
    /// publishes the file pass's three. Asserted anyway, because a card headed "hasn't run here"
    /// over a lens holding an answer would be false about the lens it names.
    @Test func aPartlyAnsweredPassIsNotOffered() {
        let subject = overview([
            section(.toFile, .findings(count: 4, headline: "4 files", examples: [])),
            section(.names, .notScanned),
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

    /// A clean lens is **not** an offer. `clean` and `notScanned` are the distinction this whole
    /// screen is careful about, and collapsing them here would put "hasn't run here" over a check
    /// that ran and came back empty.
    @Test func aCleanLensIsNotOffered() {
        let subject = overview([
            section(.toFile, .clean), section(.names, .clean), section(.renames, .clean),
        ])
        #expect(subject.pendingPasses.isEmpty)
    }

    // MARK: The ledger

    // MARK: A pass is never offered without a way to run it

    /// **No card is ever drawn for a pass this host cannot start.**
    ///
    /// The regression review found: the folder-memory card appears when there is no profile, and
    /// `ContentView` withholds `onUpdateFolderMemory` in exactly that state — so every machine that
    /// has never been surveyed carried a permanent card offering a scan that
    /// `resurveyFilingMemory` returns early from anyway.
    @Test func noPassIsOfferedWithoutAWayToRunIt() {
        let nothingScanned = OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .notScanned)
        }
        for runnable in [Set<OrganizePass>(), [.file], [.file, .duplicates],
                         Set(OrganizePass.allCases)] {
            let offered = Set(overview(nothingScanned, runnable: runnable).pendingPasses)
            #expect(offered.isSubset(of: runnable),
                    "offered \(offered) with only \(runnable) runnable")
            // **A subset assertion passes on an empty set**, so it would survive `pendingPasses`
            // breaking entirely. This is the half that proves the offers are still being made.
            #expect(offered == runnable,
                    "with nothing scanned, every runnable pass should be offered: \(offered)")
        }
    }

    /// …and the lens does not lose its report as a result: it falls back to the quiet footer line,
    /// which is what the screen showed before the card existed.
    @Test func anUnrunnablePassStillReportsThatItHasNotRun() {
        let subject = overview(OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, $0 == .restructure ? .notScanned : .clean)
        }, runnable: [.file, .duplicates])
        #expect(subject.pendingPasses.isEmpty)
        #expect(subject.strandedUnscanned.map(\.lens) == [.restructure],
                "the unrunnable lens stopped saying it had not run")
    }

    /// **One offer per pass, even in the footer.**
    ///
    /// Written per row, the footer could put two identical "Run the file pass" buttons on two
    /// stranded lenses of one walk — the defect this screen replaced, rebuilt inside its
    /// replacement. Not reachable from today's flags, which is exactly why it needs a test rather
    /// than a comment.
    /// **The first version of this could not fail**, and review caught it by deleting the dedupe
    /// from the view and watching all 29 tests stay green. It counted rows equal to
    /// `firstStrandedLens(of:)` — a single optional — so the count it asserted was `1` could only
    /// ever be 0 or 1, and it branched on its own restatement of the rule rather than on the
    /// footer's condition. This one asks ``OrganizeOverview/offersPassRun(for:)``, which is the
    /// expression the footer itself branches on.
    @Test func theFooterOffersAPassAtMostOnce() {
        // To File and Renames unscanned while Names has an answer: the file pass is not `pending`
        // (not all of its lenses are unscanned), so both fall through to the footer.
        let subject = overview([section(.toFile, .notScanned),
                                section(.names, .clean),
                                section(.renames, .notScanned)])
        #expect(subject.strandedUnscanned.map(\.lens) == [.toFile, .renames])
        let offers = subject.sections.filter { subject.offersPassRun(for: $0) }
        #expect(offers.count == 1,
                "the file pass is offered \(offers.count) times: \(offers.map(\.lens.title))")
        #expect(offers.first?.lens == .toFile, "the offer should sit on the first row, in rail order")
    }

    /// The same rule stated over every pass at once, so a second pass stranding two lenses cannot
    /// slip through a fixture built around the file pass alone.
    @Test func noPassIsEverOfferedTwiceInTheFooter() {
        // Every lens unscanned, but nothing runnable except the file pass — so its three lenses all
        // strand together (no card is offered for a pass this host cannot run either).
        let subject = overview(OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .notScanned)
        }, runnable: [])
        #expect(subject.strandedUnscanned.count == 5, "every lens should have stranded")
        for pass in OrganizePass.allCases {
            let offers = subject.sections.filter {
                subject.offersPassRun(for: $0) && pass.lenses.contains($0.lens)
            }
            #expect(offers.count <= 1, "\(pass.rawValue) offered \(offers.count) times")
        }
    }

    /// A stranded lens whose pass this host cannot run says so and offers nothing — the quiet line
    /// on its own, which is the state a machine with no filing profile lands in.
    @Test func aStrandedLensWithNoRunnablePassOffersNothing() {
        let subject = overview([section(.restructure, .notScanned)], runnable: [.file, .duplicates])
        #expect(subject.strandedUnscanned.map(\.lens) == [.restructure])
        #expect(!subject.offersPassRun(for: subject.sections[0]))
    }

    /// A lens that has already answered never draws the footer's *run* offer — that control says
    /// "this has not run", and the row's own Rescan is what an answered lens gets.
    @Test func anAnsweredLensDrawsNoRunOffer() {
        let answered = section(.duplicates, .findings(count: 3, headline: "3", examples: []))
        #expect(!overview([answered]).offersPassRun(for: answered))
    }

    /// The ledger counts a **clean** lens as run.
    ///
    /// The commonest way to get this wrong is to count the reporting ones, which would leave a
    /// fully-scanned clean tree reading "0 of 5 checks have run" — the screen contradicting its own
    /// "every check that has run came back clean" in the line below.
    @Test func aCleanLensCountsAsRun() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: [section(.toFile, .clean),
                   section(.duplicates, .findings(count: 2, headline: "2 groups", examples: [])),
                   section(.renames, .notScanned)],
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == 2)
    }

    /// The denominator is the lenses that can run — five, not six.
    ///
    /// With six, a tree where every check has completed reads "5 of 6" forever: a screen
    /// permanently claiming outstanding work that no button can ever discharge.
    @Test func theDenominatorExcludesRules() {
        let ledger = OrganizeOverview.Ledger.derived(from: [],
                                                     runnablePasses: Set(OrganizePass.allCases),
                                                     reclaimable: nil, scopeFolders: nil)
        // Four: rules never scans, and the folded Names lens is counted with its host —
        // a denominator that still counted it would read "4 of 5" forever on a clean tree.
        #expect(ledger.checksTotal == 4)
        #expect(ledger.checksTotal == OrganizeLens.railItems.count - 1)
    }

    /// Every lens run, and the ratio closes.
    @Test func aFullyScannedTreeReadsAllOfThem() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: OrganizeLens.allCases.filter(\.carriesBadge).map { section($0, .clean) },
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == ledger.checksTotal)
    }

    /// The strip stays away when it would say nothing — nothing run, no profile, nothing to
    /// reclaim. "0 of 5" over an empty pane is chrome.
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

    /// **The ratio closes on a machine that cannot run every check.**
    ///
    /// Restructure's pass is the folder survey, which needs a profile this machine may never have
    /// had — `ContentView` withholds the handler in exactly that state. Counted anyway, the ledger
    /// read "4 of 5 checks have run" **permanently**: a standing claim of outstanding work against
    /// a button that does not exist anywhere in the app. Review caught it; the numerator has to
    /// drop the same lens as the denominator, or the ratio reads "4 of 4" while one of the four is
    /// the excluded one.
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

    /// And an unrunnable lens that *has* an answer is not counted as a check either — the numerator
    /// and denominator are taken over one set, so neither can include what the other drops.
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

    /// **No two things on the overview wear the same glyph.**
    ///
    /// The overview draws the pass cards and the rail together, so a symbol shared between a pass
    /// and an unrelated lens is two meanings for one picture on one screen. The duplicate pass
    /// carried `wand.and.stars` — Rules' glyph — while the Duplicates rail item it is quoting sat
    /// beside it wearing `doc.on.doc`.
    @Test func noPassSharesAGlyphWithAnUnrelatedLens() {
        var byGlyph: [String: [String]] = [:]
        for pass in OrganizePass.allCases { byGlyph[pass.symbol, default: []].append("pass.\(pass)") }
        for lens in OrganizeLens.allCases { byGlyph[lens.symbol, default: []].append("lens.\(lens)") }
        #expect(byGlyph.count > 5, "the tables are implausibly small — this scan would be near-vacuous")

        // The one pair that legitimately shares, because one is quoting the other: the duplicate
        // pass card and the Duplicates rail item are the same act.
        //
        // `["pass.file", "lens.renames"]` used to sit here too — the file pass wore
        // `FilingGlyph.lens`, which `OrganizeLens.renames` also wears, and the two draw together on
        // the overview meaning different things. It was recorded rather than fixed because picking
        // a replacement is a visual decision; the pass has one of its own now
        // (`doc.text.magnifyingglass`, chosen for the pass and not for any single lens, since it
        // answers three), so the allowance goes with it. Leaving a stale entry here would let the
        // collision come back unnoticed.
        let quoted: Set<Set<String>> = [
            ["pass.duplicates", "lens.duplicates"],
        ]
        for (glyph, owners) in byGlyph where owners.count > 1 {
            #expect(quoted.contains(Set(owners)),
                    "\(glyph) is worn by \(owners.sorted().joined(separator: " and ")) — one picture, two meanings")
        }
    }

    /// And the quote is a quote: the pass reads the lens rather than restating its glyph.
    ///
    /// Asserting `OrganizePass.duplicates.symbol == OrganizeLens.duplicates.symbol` would compare
    /// the model to itself — production is literally `return OrganizeLens.duplicates.symbol`, so a
    /// hard-coded copy of the same string passes it too. What carries the claim is that the glyph
    /// is NOT the one it used to restate, plus the source reading as a delegation.
    @Test func theDuplicatePassWearsTheDuplicatesLensGlyph() throws {
        #expect(OrganizePass.duplicates.symbol != OrganizeLens.rules.symbol,
                "the duplicate pass card wears the Rules glyph again")
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/OrganizePass.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read OrganizePass.swift — this scan would be vacuous")
        #expect(source.contains("case .duplicates: return OrganizeLens.duplicates.symbol"),
                "the pass restates a glyph instead of asking the lens for it")
    }
}
