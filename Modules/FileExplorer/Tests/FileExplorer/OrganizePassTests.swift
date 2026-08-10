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

    // MARK: The words on the offer

    /// Every pass states a cost, and the file pass's says it is free.
    ///
    /// **Not decoration.** The lens this offer leads to contains the one control in Organize that
    /// spends money, and `TidyView.refineButton` is explicit that "the scan that produced these
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

    /// The ledger counts a **clean** lens as run.
    ///
    /// The commonest way to get this wrong is to count the reporting ones, which would leave a
    /// fully-scanned clean tree reading "0 of 5 checks have run" — the screen contradicting its own
    /// "every check that has run came back clean" in the line below.
    @Test func aCleanLensCountsAsRun() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: [section(.toFile, .clean),
                   section(.names, .findings(count: 2, headline: "2 names", examples: [])),
                   section(.renames, .notScanned)],
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == 2)
    }

    /// The denominator is the lenses that can run — five, not six.
    ///
    /// With six, a tree where every check has completed reads "5 of 6" forever: a screen
    /// permanently claiming outstanding work that no button can ever discharge.
    @Test func theDenominatorExcludesRules() {
        let ledger = OrganizeOverview.Ledger.derived(from: [], reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksTotal == 5)
        #expect(ledger.checksTotal == OrganizeLens.allCases.count - 1)
    }

    /// Every lens run, and the ratio closes.
    @Test func aFullyScannedTreeReadsAllOfThem() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: OrganizeLens.allCases.filter(\.carriesBadge).map { section($0, .clean) },
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == ledger.checksTotal)
    }

    /// The strip stays away when it would say nothing — nothing run, no profile, nothing to
    /// reclaim. "0 of 5" over an empty pane is chrome.
    @Test func anUnscannedTreeHasNoLedgerToDraw() {
        let empty = OrganizeOverview.Ledger.derived(
            from: OrganizeLens.allCases.filter(\.carriesBadge).map { section($0, .notScanned) },
            reclaimable: nil, scopeFolders: nil)
        #expect(empty.isEmpty)
        #expect(!OrganizeOverview.Ledger
            .derived(from: [], reclaimable: nil, scopeFolders: 3_013).isEmpty)
    }

    /// Three examples, because the row has the room and one is a sample of size one.
    @Test func theExampleLimitIsThree() {
        #expect(OrganizeOverview.exampleLimit == 3)
    }
}
