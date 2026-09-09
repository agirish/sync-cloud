import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// **Organize's overview is one card system, and these are the rules that make it one.**
///
/// The complaint this suite was written against was a screenshot and a list: *everything is
/// different and not consistent — Storage doesn't even have a card, Restructure has a colour card,
/// the Refresh buttons don't line up, the buttons don't all have the blue background pill, the
/// heights of the cards don't match.* Five observations, one cause: five card anatomies had grown
/// on one screen, each locally reasonable, none of them agreeing with the others about surface,
/// verb dress, verb position or height.
///
/// Every claim below is one of those five, stated so it can fail. The value-level ones are here
/// rather than in pixels for the usual reason — a rule and the thing under test have to be one
/// expression — and the one pixel test is the one claim that has no value to assert against: what
/// a card is *made of*.
@MainActor
@Suite struct OverviewCardConsistencyTests {

    // MARK: Fixture

    private static func section(_ lens: OrganizeLens, _ state: OrganizeOverviewState,
                                scanning: Bool = false) -> OrganizeOverviewSection {
        OrganizeOverviewSection(lens: lens, blurb: "What this lens is about.", state: state,
                                isScanning: scanning)
    }

    private static func overview(_ sections: [OrganizeOverviewSection],
                                 runnable: Set<OrganizePass> = Set(OrganizePass.allCases),
                                 buildStorage: (() -> Void)? = {}) -> OrganizeOverview {
        OrganizeOverview(sections: sections, scopeLabel: nil, accent: .blue,
                         ledger: OrganizeOverview.Ledger(),
                         runnablePasses: runnable,
                         onOpen: { _ in }, onRun: { _ in },
                         onBuildStorage: buildStorage)
    }

    // MARK: The verbs agree about rank and about where they sit

    /// **The primary is drawn last, so every card's main verb lands on one vertical line.**
    ///
    /// This is the "the Refresh buttons don't line up" complaint, reduced to the rule that fixes
    /// it. The action row is flush to the card's trailing padding, so whichever verb is drawn last
    /// is the one whose right edge is shared by every card on the page — and that has to be the
    /// primary, or the alignment lands on whichever card happens to have the most verbs.
    @Test func thePrimaryIsDrawnLastAndTheOthersKeepTheirOrder() {
        let actions = [OverviewCardAction(title: "Stop", run: {}),
                       OverviewCardAction(title: "Pause", rank: .primary, run: {}),
                       OverviewCardAction(title: "Start over", run: {})]
        #expect(OverviewCardAction.drawingOrder(actions).map(\.title)
                == ["Stop", "Start over", "Pause"])
    }

    /// A card with no primary keeps its order untouched rather than promoting one by accident.
    @Test func aCardWithNoPrimaryIsLeftAlone() {
        let actions = [OverviewCardAction(title: "One", run: {}),
                       OverviewCardAction(title: "Two", run: {})]
        #expect(OverviewCardAction.drawingOrder(actions).map(\.title) == ["One", "Two"])
    }

    /// **At most one blue pill per card, in every state any of them can be in.**
    ///
    /// The "buttons don't all have the blue background pill" complaint has two halves and this is
    /// the second: not merely that every verb is a button, but that a card cannot grow two verbs
    /// competing to be the important one. Enumerated over every card the overview can draw rather
    /// than asserted per call site, so a new state that forgets the rule fails here.
    @Test func noCardOffersTwoPrimaries() {
        for lens in OrganizeLens.allCases {
            for state in Self.everyState {
                for scanning in [false, true] {
                    let section = Self.section(lens, state, scanning: scanning)
                    let actions = Self.overview([section]).actions(for: section)
                    #expect(actions.filter { $0.rank == .primary }.count <= 1,
                            "\(lens.title) offers two primaries")
                }
            }
        }
    }

    /// The document survey's five states obey the same rule, and it is the card that broke it
    /// worst: its settled Refresh was a bare accent word with no button shape at all.
    @Test func theDocumentSurveyOffersOnePrimaryPerState() {
        let states: [DocumentSurveyCardState] = [
            .offered(documents: 11_019),
            .running(done: 10, total: 100, folder: "Legal", secondsRemaining: 600, pause: nil),
            .running(done: 10, total: 100, folder: nil, secondsRemaining: nil,
                     pause: .init(sentence: "On battery.", resumesOnItsOwn: true)),
            .running(done: 10, total: 100, folder: nil, secondsRemaining: nil,
                     pause: .init(sentence: "You paused it.", resumesOnItsOwn: false)),
            .finishing(done: 7_558),
            .interrupted(done: 7_558, total: 11_019),
            .finished(summary: "Read 11,019 documents.", unreadableTypes: 0),
            .settled(folders: 2_309, lastRead: Date())]
        for state in states {
            let card = DocumentSurveyCard(state: state, accent: .blue, onStart: {}, onResume: {},
                                          onPause: {}, onStop: {}, onOpenHelp: {}, onUpdate: {})
            let primaries = card.verbs.filter { $0.rank == .primary }
            #expect(primaries.count <= 1,
                    "\(DocumentSurveyCardText.title(for: state)) offers \(primaries.count) primaries")
        }
        // **And Stop never takes the trailing slot.** `drawingOrder` puts a primary last, so a
        // state that has one is safe by construction — but the auto-resume pause has none on
        // purpose ("Resume now" is an impatience valve, not the way out), and listing Stop last
        // there put the one destructive verb on this page in the position the layout reserves for
        // a card's main verb.
        for state in states {
            let card = DocumentSurveyCard(state: state, accent: .blue, onStart: {}, onResume: {},
                                          onPause: {}, onStop: {}, onOpenHelp: {}, onUpdate: {})
            let drawn = OverviewCardAction.drawingOrder(card.verbs).map(\.title)
            #expect(drawn.last != "Stop" && drawn.last != "Start over",
                    "\(DocumentSurveyCardText.title(for: state)) ends its row with \(drawn.last ?? "")")
        }

        // And the settled receipt's one verb IS the primary — the specific control the complaint
        // named, which used to be the only unshaped button on the screen.
        let settled = DocumentSurveyCard(state: .settled(folders: 2_309, lastRead: nil),
                                         accent: .blue, onUpdate: {})
        #expect(settled.verbs.map(\.rank) == [.primary])
    }

    /// **A card's verbs are distinct, or `ForEach` silently draws one of them.**
    ///
    /// `OverviewCardAction` is `Identifiable` on its title, so two verbs sharing a title on one
    /// card collapse to a single button with no error anywhere. Nothing does that today; this is
    /// what makes it stay that way, and it costs one sweep over the states that already exist.
    @Test func noCardOffersTwoVerbsWithTheSameName() {
        for lens in OrganizeLens.allCases {
            for state in Self.everyState {
                for scanning in [false, true] {
                    let section = Self.section(lens, state, scanning: scanning)
                    let titles = Self.overview([section]).actions(for: section).map(\.title)
                    #expect(titles.count == Set(titles).count,
                            "\(lens.title) offers two verbs called the same thing: \(titles)")
                }
            }
        }
    }

    /// The states a lens's card can be in, for the sweeps above and below.
    private static let everyState: [OrganizeOverviewState] = [
        .findings(count: 7, headline: "7 groups", examples: ["a — 2 copies"]),
        .receipt(headline: "214.6 GB total", detail: "Analyzed Tuesday · ~/Documents"),
        .notScanned,
        .clean]

    // MARK: What a card withdraws while its work runs

    /// **A scan in flight takes away the verb that starts it, and never the way in.**
    ///
    /// The first draft of the card system returned no verbs at all for a findings card while its
    /// scan ran, which took `Open Duplicates` off the screen for the whole of a rehash — minutes,
    /// on the one card whose answer somebody might well want to read while it is being recomputed.
    /// The layout it replaced never did that: its Open was unconditional and only the rescan was
    /// withdrawn.
    ///
    /// Nothing caught it. The two render tests that watch a scanning row are satisfied by any large
    /// change to that row, and a row that loses two controls instead of one changes more, not less.
    /// A claim about *which* control survives cannot be made in pixels at all.
    @Test func aScanInFlightWithdrawsTheRescanAndKeepsTheWayIn() {
        let finding = OrganizeOverviewState.findings(count: 722, headline: "722 groups",
                                                     examples: ["clip.mp4 — 2 copies"])
        let idle = Self.section(.duplicates, finding)
        let running = Self.section(.duplicates, finding, scanning: true)
        let page = Self.overview([idle])

        #expect(page.actions(for: idle).map(\.title) == ["Open Duplicates", "Rescan"])
        #expect(page.actions(for: running).map(\.title) == ["Open Duplicates"],
                "a rescan in flight left \(page.actions(for: running).map(\.title)) on the card")
    }

    /// The same rule on the receipt: the report can still be opened while the next one is built,
    /// and the verb that builds it is withdrawn rather than drawn greyed beside its own spinner.
    @Test func aReceiptBeingRebuiltKeepsItsWayInAndDropsItsVerb() {
        let receipt = OrganizeOverviewState.receipt(headline: "214.6 GB total",
                                                    detail: "Analyzed Tuesday · ~/Documents")
        let idle = Self.section(.storage, receipt)
        let running = Self.section(.storage, receipt, scanning: true)
        let page = Self.overview([idle])

        #expect(page.actions(for: idle).map(\.title) == ["Open Storage", "Re-analyze"])
        #expect(page.actions(for: running).map(\.title) == ["Open Storage"])
    }

    /// **And a card being worked on stays a card.**
    ///
    /// `strandedCards`/`strandedLines` first partitioned on "does this section have actions right
    /// now", which is the moment rather than the standing fact — so pressing Analyze withdrew
    /// Storage's verb, the partition read "nothing to offer", and the card you had just acted on
    /// demoted itself to a line of grey footer text for the whole run.
    @Test func aStrandedLensBeingScannedKeepsItsCard() {
        let running = Self.section(.storage, .notScanned, scanning: true)
        let page = Self.overview([running])
        #expect(page.strandedCards.contains { $0.lens == .storage },
                "Storage fell out of the cards the moment its own analysis started")
        #expect(page.strandedLines.isEmpty)
        #expect(page.actions(for: running).isEmpty,
                "the card still offers to start work that is already running")
    }

    /// **The small print does not come and go with the scan.**
    ///
    /// It was keyed on `offersRescan`, which also asks whether a scan is in flight — so the card's
    /// whole bottom rule and cost line vanished the moment you pressed Refresh and came back when
    /// it finished. A card that changes height while you watch it work is the same defect
    /// ``OrganizePass/answersOneLens`` exists to prevent one row up: the control must not move with
    /// the data, and neither must its price tag.
    @Test func theCostLineHoldsStillWhileTheScanRuns() {
        let finding = OrganizeOverviewState.findings(count: 1, headline: "1 finding", examples: [])
        let page = Self.overview([Self.section(.restructure, finding)])
        let idle = Self.section(.restructure, finding)
        let running = Self.section(.restructure, finding, scanning: true)
        #expect(page.findingsNote(idle)?.text == OrganizePass.folderMemory.offerCost)
        #expect(page.findingsNote(running)?.text == OrganizePass.folderMemory.offerCost,
                "the cost line went away mid-scan — the card changes height while it works")
        // And it is still absent where there is no verb to price: the file pass answers two lenses,
        // so To File carries no rescan and nothing to say about its cost.
        #expect(page.findingsNote(Self.section(.toFile, finding)) == nil)
    }

    /// **A never-run lens's heading is about the lens, not about its pass.**
    ///
    /// Quoting `OrganizePass.offerTitle` read better and was wrong: a lens reaches this card only
    /// when its pass has answered some of its *other* lenses and not this one, so "The file pass
    /// hasn't run here" would contradict an answer sitting a card above it. Cold today — the one
    /// multi-lens pass publishes both lenses from a single flag — and a sentence that is false the
    /// moment its branch goes live is not made safe by the branch being cold.
    @Test func aStrandedHeadingNamesTheLensAndNotThePass() {
        #expect(OrganizeOverview.strandedTitle(.storage) == "Storage hasn’t been analyzed here",
                "Storage does not run — its heading has to use the verb its button uses")
        #expect(OrganizeOverview.strandedTitle(.toFile) == "To File hasn’t run here")
        for lens in OrganizeLens.allCases {
            guard let pass = OrganizePass(producing: lens) else { continue }
            #expect(OrganizeOverview.strandedTitle(lens) != pass.offerTitle,
                    "\(lens.title)'s stranded heading claims its whole pass never ran here")
        }
    }

    // MARK: The nudge rides the card it is about

    private static func nudge() -> OrganizeOverview.BacklogNudge {
        .init(sentence: "2026 has files but no folders yet in Health/Dental.",
              setUp: {}, dismiss: {})
    }

    private static func page(_ sections: [OrganizeOverviewSection],
                             nudge: OrganizeOverview.BacklogNudge?) -> OrganizeOverview {
        OrganizeOverview(sections: sections, scopeLabel: nil, accent: .blue,
                         backlogNudge: nudge,
                         ledger: OrganizeOverview.Ledger(),
                         runnablePasses: Set(OrganizePass.allCases),
                         onOpen: { _ in }, onRun: { _ in }, onBuildStorage: {})
    }

    /// **A due nudge belongs to Restructure's card, because it names one of that card's findings.**
    ///
    /// `LensWorkspaceView.backlogNudge()` derives it from `scopedStructureFindings`; the overview's
    /// Restructure arm counts the same `structureFindings` through the same `.inside` scope filter.
    /// `RestructureNudge.due` is a subset of that list, so the folder in the sentence is one of the
    /// findings the pill above it counts. Drawn as a card of its own it read as a second, headless
    /// subject wedged between the ledger and the card it was talking about.
    @Test func aDueNudgeAttachesToTheCardWhoseFindingItNames() {
        let reporting = Self.section(.restructure,
                                     .findings(count: 53, headline: "53 findings", examples: []))
        #expect(Self.page([reporting], nudge: Self.nudge()).nudgeHost?.lens == .restructure)
    }

    /// And nothing attaches when nothing is due — the host is about the nudge, not about the card.
    @Test func noNudgeMeansNoHost() {
        let reporting = Self.section(.restructure,
                                     .findings(count: 53, headline: "53 findings", examples: []))
        #expect(Self.page([reporting], nudge: nil).nudgeHost == nil)
    }

    /// **A nudge with no host still draws**, on the rung it used to have all to itself.
    ///
    /// The two derivations are provably in step today, so this state is unreachable: a nudge is due
    /// only when the findings it came from are on the card. The fallback exists because the failure
    /// it guards is silent — a time-sensitive line vanishing is the exact thing §5.6 was written to
    /// prevent — and an unreachable state with a defined answer costs one branch.
    @Test func theNudgeSurvivesLosingItsHost() throws {
        let clean = Self.section(.restructure, .clean)
        let page = Self.page([clean], nudge: Self.nudge())
        #expect(page.nudgeHost == nil, "a clean Restructure is not a card to hang a nudge on")

        // And it reaches the pixels rather than merely being modelled: the same page without a
        // nudge draws measurably less.
        let with = try #require(Self.render(page))
        let without = try #require(Self.render(Self.page([clean], nudge: nil)))
        var differing = 0
        for y in 0..<min(with.pixelsHigh, without.pixelsHigh) {
            for x in 0..<min(with.pixelsWide, without.pixelsWide) {
                guard let a = with.colorAt(x: x, y: y), let b = without.colorAt(x: x, y: y) else {
                    continue
                }
                if max(abs(a.redComponent - b.redComponent),
                       max(abs(a.greenComponent - b.greenComponent),
                           abs(a.blueComponent - b.blueComponent))) > 0.04 { differing += 1 }
            }
        }
        #expect(differing > 2000, "a homeless nudge drew nothing — it is lost, not relocated")
    }

    // MARK: Storage has a card

    /// **The complaint, as a test.** Storage before its first analysis is a lens with a verb and a
    /// real answer to give, and it drew a line of tertiary grey text in the footer.
    ///
    /// It is still *stranded* — no ``OrganizePass`` produces it, and that is a fact about the
    /// machinery, not about the design — so the assertion is on what a stranded lens draws, which
    /// is the thing that changed. `strandedCards` and `strandedLines` partition
    /// `strandedUnscanned`, so a lens cannot quietly fall out of both.
    @Test func aNeverAnalyzedStorageTakesACardAndNotAFootnote() {
        let page = Self.overview([Self.section(.storage, .notScanned)])
        #expect(page.strandedCards.contains { $0.lens == .storage },
                "Storage before its first analysis is still a footer line")
        #expect(!page.strandedLines.contains { $0.lens == .storage })
    }

    /// **And a host that cannot analyze still gets the line, not a dead card.** The rule the footer
    /// existed for in the first place: a card offering a scan nothing can start is strictly worse
    /// than a sentence saying it has not run.
    @Test func aStorageWithNoAnalyzerStaysAQuietLine() {
        let page = Self.overview([Self.section(.storage, .notScanned)], buildStorage: nil)
        #expect(page.strandedLines.contains { $0.lens == .storage })
        #expect(page.strandedCards.isEmpty)
    }

    /// The partition holds for every stranded lens, not just Storage — a lens in neither list would
    /// vanish from the screen entirely, which is the failure mode with no visible symptom.
    @Test func everyStrandedLensIsDrawnExactlyOnce() {
        let sections = OrganizeLens.allCases.map { Self.section($0, .notScanned) }
        let page = Self.overview(sections, runnable: [])
        let drawn = Set(page.strandedCards.map(\.lens)).union(page.strandedLines.map(\.lens))
        #expect(drawn == Set(page.strandedUnscanned.map(\.lens)))
        #expect(Set(page.strandedCards.map(\.lens))
            .isDisjoint(with: Set(page.strandedLines.map(\.lens))))
    }

    // MARK: A card with nothing to show is not taller for it

    /// **An empty content slot costs a card 7pt of dead air, and two of the four findings cards
    /// are in that state.**
    ///
    /// `OverviewCard` separates its heading from its content by 7pt. An empty `VStack` is still a
    /// view, so a slot built unconditionally and then filled with nothing takes that spacing and
    /// pads the card's bottom with it — measured at 60pt against 53pt for the same card handed
    /// `EmptyView`. Renames and Restructure both summarise in the blurb now and pass no rows at
    /// all, so this was card heights disagreeing again for a reason invisible in the source: the
    /// difference between `if x { VStack { … } }` and `VStack { if x { … } }`.
    ///
    /// Measured through the real cards rather than through `OverviewCard` directly, so the claim is
    /// about what the overview builds and not about what the container can be made to do.
    @Test func aFindingsCardWithNoRowsIsNoTallerForIt() {
        let bare = Self.section(.renames, .findings(count: 126, headline: "126 to change",
                                                    examples: []))
        let withRows = Self.section(.renames, .findings(count: 126, headline: "126 to change",
                                                        examples: ["a.pdf → Finance"]))
        let bareHeight = Self.cardHeight(bare)
        let rowsHeight = Self.cardHeight(withRows)
        // The two values this sits between are measured, not guessed: 53pt correct, 60pt with the
        // slot built unconditionally — the outer stack's 7pt spacing, paid for nothing. 57 leaves
        // four points of margin on each side, where the 60 this started at left none and would
        // have flipped on a half-point of font metric.
        #expect(bareHeight < 57,
                "a findings card with no rows is \(Int(bareHeight))pt — it is paying for a content slot it does not fill")
        #expect(rowsHeight > bareHeight + 10,
                "adding a row changed the card by \(Int(rowsHeight - bareHeight))pt — the probe is not measuring the slot")
    }

    /// And the nudge is content too: hosted on its card, it earns the slot back.
    @Test func aHostedNudgeGivesItsCardTheSlot() {
        let reporting = Self.section(.restructure,
                                     .findings(count: 53, headline: "53 findings", examples: []))
        let quiet = Self.cardHeight(reporting, nudge: nil)
        let nudged = Self.cardHeight(reporting, nudge: Self.nudge())
        #expect(nudged > quiet + 10,
                "the nudge added \(Int(nudged - quiet))pt to its host card — it is not being drawn")
    }

    /// One findings card's rendered height, off the real view.
    private static func cardHeight(_ section: OrganizeOverviewSection,
                                   nudge: OrganizeOverview.BacklogNudge? = nil) -> CGFloat {
        let page = OrganizeOverview(sections: [section], scopeLabel: nil, accent: .blue,
                                    backlogNudge: nudge,
                                    ledger: OrganizeOverview.Ledger(),
                                    runnablePasses: Set(OrganizePass.allCases),
                                    onOpen: { _ in }, onRun: { _ in })
        // The page's own 14pt padding top and bottom is the only other tenant with one section.
        let host = NSHostingView(rootView: AnyView(page.frame(width: 560)))
        return host.fittingSize.height - 28
    }

    // MARK: The surface is one surface

    /// **A finding and an offer are made of the same thing.**
    ///
    /// The "Restructure has a colour card" complaint. A findings card used to be a wash of
    /// `accent.opacity(0.07)` with a 3pt accent bar down its leading edge while every card around
    /// it was a grey well — one card in six looking like it came from a different app, to carry a
    /// signal the accent glyph tile and the accent count pill already carry.
    ///
    /// Measured, not asserted: the same lens is rendered twice, once reporting and once not, and
    /// the card's own fill is sampled at the leading edge where no content reaches. Finding the
    /// card's top edge by scanning down rather than hardcoding a y keeps this from breaking on a
    /// spacing change while still failing on a tint.
    @Test func aFindingAndAnOfferAreDrawnOnTheSameSurface() throws {
        let reporting = try #require(Self.cardFill(
            [Self.section(.duplicates,
                          .findings(count: 722, headline: "722 groups",
                                    examples: ["clip.mp4 — 2 copies"]))]))
        let offer = try #require(Self.cardFill([Self.section(.duplicates, .notScanned)]))
        let delta = max(abs(reporting.redComponent - offer.redComponent),
                        max(abs(reporting.greenComponent - offer.greenComponent),
                            abs(reporting.blueComponent - offer.blueComponent)))
        #expect(delta < 0.02,
                "the reporting card's fill is \(reporting), the offer's \(offer) — one is tinted")
    }

    /// The probe has to be able to fail, so: the *glyph tile* on the same two cards does differ,
    /// which is where the accent went when it left the card.
    @Test func theToneStillReachesTheGlyph() throws {
        let reporting = try #require(Self.glyphFill(
            [Self.section(.duplicates,
                          .findings(count: 722, headline: "722 groups", examples: []))]))
        let offer = try #require(Self.glyphFill([Self.section(.duplicates, .notScanned)]))
        let delta = max(abs(reporting.redComponent - offer.redComponent),
                        max(abs(reporting.greenComponent - offer.greenComponent),
                            abs(reporting.blueComponent - offer.blueComponent)))
        #expect(delta > 0.02,
                "a reporting glyph tile is indistinguishable from an offer's — nothing says work")
    }

    // MARK: The verbs land on one line

    /// **Every card's main verb ends at the same x — including the one card that can be
    /// dismissed.** This is the reported complaint stated literally, and it is the one claim on
    /// this screen that only pixels can make: "the primary is drawn last" is a fact about an array,
    /// and an array says nothing about where a control lands once a × is drawn beside it.
    ///
    /// It caught exactly that. With the dismissal at the trailing edge — the banner convention —
    /// the nudge's *Set up…* sat about 12pt inboard of every other primary, so the single card with
    /// a way out was the single card whose verb missed the line.
    ///
    /// Measured per card, because two things sit further right than a button and neither is one:
    /// the card's own hairline, and the button's rounded corners. The border is excluded by
    /// starting the walk *inside* the card rather than at the canvas edge; the corners are handled
    /// by taking each card's furthest reach rather than every row's, since a capsule's flat
    /// trailing edge is by definition the furthest right it goes.
    ///
    /// A first version compared every row and failed at 14.5pt on a correct layout — it was
    /// measuring the curve of the capsules and the corner of the cards, which is the shape of
    /// probe that reports a defect wherever you point it.
    @Test func everyCardsPrimaryEndsOnTheSameLine() throws {
        try Self.assertVerbsLineUp(width: Self.canvas.width, scale: 1)
    }

    /// **And they still do at every text size, on a pane narrow enough to squeeze them.**
    ///
    /// The buttons are `.fixedSize()` and the titles wrap, so a card under pressure degrades by
    /// growing taller — which is right, and which nothing here was checking. At 135% on a 420pt
    /// pane the longest heading on the page ("The documents here haven't been read") shares its row
    /// with the longest verb ("Read my documents"); if the trailing cluster were ever allowed to
    /// compress instead, the verbs would stop agreeing about where they end and the page's one
    /// organising line would go with them.
    ///
    /// The rail already tests itself this way (`OrganizeRailTests` runs its width model over
    /// `FontSize.allCases`); this screen was mounted at 1× only.
    @Test(arguments: FontSize.allCases)
    func theVerbsLineUpAtEveryTextSize(size: FontSize) throws {
        try Self.assertVerbsLineUp(width: 420, scale: size.scale)
    }

    private static func assertVerbsLineUp(width: CGFloat, scale: CGFloat) throws {
        let sections = [Self.section(.restructure,
                                     .findings(count: 53, headline: "53 findings",
                                               examples: ["Finance/US — 11 folders, 3 schemes"])),
                        Self.section(.duplicates, .notScanned),
                        Self.section(.storage, .notScanned)]
        let page = OrganizeOverview(
            sections: sections, scopeLabel: nil, accent: .blue,
            inboxShortcut: .init(name: "TODO", looseFileCount: 42, apply: {}),
            backlogNudge: .init(sentence: "2026 has files but no folders yet in Health/Dental.",
                                setUp: {}, dismiss: {}),
            ledger: OrganizeOverview.Ledger(),
            runnablePasses: Set(OrganizePass.allCases),
            onOpen: { _ in }, onRun: { _ in }, onBuildStorage: {})
        let rep = try #require(render(page, width: width, fontScale: scale))
        let pixels = CGFloat(rep.pixelsWide) / width
        let ground = try #require(rep.colorAt(x: rep.pixelsWide - 3, y: rep.pixelsHigh - 3))

        /// Whether this pixel is **button fill** rather than text or a hairline.
        ///
        /// Two properties separate them and the probe needs both. A button is a solid capsule in a
        /// mid tone — light grey over the light ground, well short of glyph ink — so the *colour*
        /// rules out text, whose strokes are near-black, and the *run length* below rules out both
        /// a card's one-pixel hairline and the antialiased edge of a letter.
        ///
        /// The first version keyed on "differs from the ground at all" and read wrapped headings as
        /// controls the moment the pane was narrow enough for a title to reach the gutter — it
        /// reported a 110pt spread on a layout that was correct, at every text size, which is the
        /// probe measuring the fixture instead of the claim.
        ///
        /// Light mode only, and that is what `render` pins: the band is stated against a light
        /// ground and would have to be restated for a dark one. `lensCard()`'s own light/dark
        /// behaviour is pinned in `DesignSnapshotTests`, not here.
        func isButtonFill(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            let delta = max(abs(c.redComponent - ground.redComponent),
                            max(abs(c.greenComponent - ground.greenComponent),
                                abs(c.blueComponent - ground.blueComponent)))
            return delta > 0.02 && delta < 0.35
        }
        // A capsule is at least this wide even for the shortest verb on the page; no glyph is.
        let solid = Int(8 * pixels)
        // Start inside the card: the page insets every card by 14pt, so anything at or beyond that
        // is the card's own edge and not a control on it.
        let from = Int((width - 18) * pixels)

        /// The trailing edge of the rightmost button on this row, in points.
        func trailingEdge(_ y: Int) -> CGFloat? {
            var run = 0
            var end: Int?
            for x in stride(from: from, through: 0, by: -1) {
                if isButtonFill(x, y) {
                    if run == 0 { end = x }
                    run += 1
                    if run >= solid, let end { return CGFloat(end + 1) / pixels }
                } else {
                    run = 0
                }
            }
            return nil
        }
        // Rows whose rightmost button reaches the gutter — every card's action row, and nothing
        // else, since this fixture draws no ledger strip (`Ledger()` is empty) and a count pill
        // always sits left of the verbs it accompanies.
        let gutter = width - 140
        let rows = (0..<rep.pixelsHigh).map { trailingEdge($0).flatMap { $0 > gutter ? $0 : nil } }
        var bands: [[CGFloat]] = []
        for row in rows {
            if let row {
                if bands.isEmpty || bands[bands.count - 1].isEmpty { bands.append([]) }
                bands[bands.count - 1].append(row)
            } else if !(bands.last?.isEmpty ?? true) {
                bands.append([])
            }
        }
        // Max per band, not per row: a capsule's rounded corners reach less far than its flat edge,
        // and a card's furthest reach is by definition that edge.
        let reaches = bands.filter { $0.count > 4 }.compactMap { $0.max() }
        // Restructure, the duplicate pass, Storage, the nudge and the inbox all carry a verb.
        #expect(reaches.count >= 5,
                "found \(reaches.count) action rows at \(Int(width))pt/\(scale)× — the probe is not seeing every card's verb")
        let spread = (reaches.max() ?? 0) - (reaches.min() ?? 0)
        #expect(spread < 1.5,
                "at \(Int(width))pt/\(scale)× the verbs end between \(Int(reaches.min() ?? 0)) and \(Int(reaches.max() ?? 0))pt — they do not line up")
    }

    private static let canvas = CGSize(width: 560, height: 700)

    /// Renders an overview and returns the colour of the first card's own fill, sampled at the
    /// leading edge inside it — left of the glyph tile, so no content can reach the probe.
    private static func cardFill(_ sections: [OrganizeOverviewSection]) -> NSColor? {
        sample(sections, x: 18)
    }

    /// The same walk one glyph-tile in: 14pt page padding + 11pt card padding puts the tile's
    /// middle at about x = 35.
    private static func glyphFill(_ sections: [OrganizeOverviewSection]) -> NSColor? {
        sample(sections, x: 36)
    }

    private static func sample(_ sections: [OrganizeOverviewSection], x: Int) -> NSColor? {
        guard let rep = render(sections) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / canvas.width
        let column = Int(CGFloat(x) * scale)
        // The window ground, read where nothing is ever drawn.
        guard let ground = rep.colorAt(x: rep.pixelsWide - 3, y: rep.pixelsHigh - 3) else {
            return nil
        }
        func differs(_ y: Int) -> Bool {
            guard let c = rep.colorAt(x: column, y: y) else { return false }
            return max(abs(c.redComponent - ground.redComponent),
                       max(abs(c.greenComponent - ground.greenComponent),
                           abs(c.blueComponent - ground.blueComponent))) > 0.008
        }
        // The first row that is not the window ground is the card's top hairline; step past it and
        // past the corner's curve before reading the fill.
        guard let top = (0..<rep.pixelsHigh).first(where: differs) else { return nil }
        return rep.colorAt(x: column, y: top + Int(14 * scale))
    }

    private static func render(_ sections: [OrganizeOverviewSection]) -> NSBitmapImageRep? {
        render(overview(sections))
    }

    private static func render(_ page: OrganizeOverview, width: CGFloat? = nil,
                               fontScale: CGFloat = 1) -> NSBitmapImageRep? {
        // Tall enough that a 135% render still fits every card — a page that overflowed would clip
        // the last card's verb and the probe would simply not see it.
        let size = CGSize(width: width ?? canvas.width, height: canvas.height * (1 + fontScale))
        let subject = page
            .environment(\.appFontScale, fontScale)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
