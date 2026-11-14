import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's overview is one card system, and these are the rules that make it one: every card
/// agrees with the others about surface, verb dress, verb position and height, and every lens gets
/// a card.
///
/// The value-level claims are asserted on values, so the rule and the thing under test are one
/// expression. Pixels are used only where there is no value to assert against: what a card is made
/// of, and where its verbs land.
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
                                 buildStorage: (() -> Void)? = {},
                                 nudge: OrganizeOverview.BacklogNudge? = nil) -> OrganizeOverview {
        OrganizeOverview(sections: sections, scopeLabel: nil, accent: .blue,
                         backlogNudge: nudge,
                         ledger: OrganizeOverview.Ledger(),
                         runnablePasses: runnable,
                         onOpen: { _ in }, onRun: { _ in },
                         onBuildStorage: buildStorage)
    }

    // MARK: The verbs agree about rank and about where they sit

    /// The primary is drawn last, so every card's main verb lands on one vertical line. The action
    /// row is flush to the card's trailing padding, so the verb drawn last is the one whose right
    /// edge every card shares; if that were not the primary, the alignment would follow whichever
    /// card has the most verbs.
    @Test func thePrimaryIsDrawnLastAndTheOthersKeepTheirOrder() {
        let actions = [OverviewCardAction(title: "Stop", run: {}),
                       OverviewCardAction(title: "Pause", rank: .primary, run: {}),
                       OverviewCardAction(title: "Start over", run: {})]
        #expect(OverviewCardAction.drawingOrder(actions).map(\.title)
                == ["Stop", "Start over", "Pause"])
        // A card with no primary keeps its order untouched rather than promoting one by accident.
        let plain = [OverviewCardAction(title: "One", run: {}),
                     OverviewCardAction(title: "Two", run: {})]
        #expect(OverviewCardAction.drawingOrder(plain).map(\.title) == ["One", "Two"])
    }

    /// At most one primary per card, in every state any card can be in, so no card grows two verbs
    /// competing to be the important one. Enumerated over every card the overview can draw, so a
    /// new state that forgets the rule fails here.
    ///
    /// And a card's verbs are distinct, or `ForEach` silently draws one of them:
    /// `OverviewCardAction` is `Identifiable` on its title, so two verbs with one title collapse to
    /// a single button with no error anywhere.
    @Test func noCardOffersTwoPrimariesOrTwoVerbsWithTheSameName() {
        for lens in OrganizeLens.allCases {
            for state in Self.everyState {
                for scanning in [false, true] {
                    let section = Self.section(lens, state, scanning: scanning)
                    let actions = Self.overview([section]).actions(for: section)
                    #expect(actions.filter { $0.rank == .primary }.count <= 1,
                            "\(lens.title) offers two primaries")
                    let titles = actions.map(\.title)
                    #expect(titles.count == Set(titles).count,
                            "\(lens.title) offers two verbs called the same thing: \(titles)")
                }
            }
        }
    }

    /// The document survey's states obey the same rule, including the settled Refresh, which must
    /// be a shaped button like every other verb.
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
        // And Stop never takes the trailing slot. `drawingOrder` puts a primary last, so a state
        // with one is safe, but the auto-resume pause has none on purpose ("Resume now" is an
        // impatience valve, not the way out), and listing Stop last there would put the page's one
        // destructive verb where the layout puts a card's main verb.
        for state in states {
            let card = DocumentSurveyCard(state: state, accent: .blue, onStart: {}, onResume: {},
                                          onPause: {}, onStop: {}, onOpenHelp: {}, onUpdate: {})
            let drawn = OverviewCardAction.drawingOrder(card.verbs).map(\.title)
            #expect(drawn.last != "Stop" && drawn.last != "Start over",
                    "\(DocumentSurveyCardText.title(for: state)) ends its row with \(drawn.last ?? "")")
        }

        // And the settled receipt's one verb is the primary.
        let settled = DocumentSurveyCard(state: .settled(folders: 2_309, lastRead: nil),
                                         accent: .blue, onUpdate: {})
        #expect(settled.verbs.map(\.rank) == [.primary])
    }

    /// The states a lens's card can be in, for the sweeps above and below.
    private static let everyState: [OrganizeOverviewState] = [
        .findings(count: 7, headline: "7 groups", examples: ["a — 2 copies"]),
        .receipt(headline: "214.6 GB total", detail: "Analyzed Tuesday · ~/Documents"),
        .notScanned,
        .clean]

    // MARK: What a card withdraws while its work runs

    /// A scan in flight takes away the verb that starts it, and never the way in. `Open Duplicates`
    /// must stay on screen through a rehash that can take minutes, since someone may want to read
    /// the answer while it is recomputed. Only an action list can say which control survives; the
    /// render tests that watch a scanning row would pass a row that lost both.
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

        #expect(page.actions(for: idle).map(\.title) == ["Open Storage", "Rescan"])
        #expect(page.actions(for: running).map(\.title) == ["Open Storage"])
    }

    /// And a card being worked on stays a card. `strandedCards`/`strandedLines` must partition on
    /// the standing fact, not on "does this section have actions right now": pressing Analyze
    /// withdraws Storage's verb, and the card just acted on must not demote itself to a grey footer
    /// line for the whole run.
    @Test func aStrandedLensBeingScannedKeepsItsCard() {
        let running = Self.section(.storage, .notScanned, scanning: true)
        let page = Self.overview([running])
        #expect(page.strandedCards.contains { $0.lens == .storage },
                "Storage fell out of the cards the moment its own analysis started")
        #expect(page.strandedLines.isEmpty)
        #expect(page.actions(for: running).isEmpty,
                "the card still offers to start work that is already running")
    }

    /// The small print does not come and go with the scan. Keyed on `offersRescan`, which also asks
    /// whether a scan is in flight, the bottom rule and cost line would vanish on Refresh and
    /// return when it finished. A card that changes height while it works is what
    /// ``OrganizePass/answersOneLens`` prevents one row up: the price tag must not move with the
    /// data.
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

    /// A never-run lens's heading is about the lens, not its pass. A lens reaches this card only
    /// when its pass has answered some of its other lenses and not this one, so quoting
    /// `OrganizePass.offerTitle` ("The file pass hasn't run here") would contradict an answer a
    /// card above it. The branch is cold today, since the one multi-lens pass publishes both lenses
    /// from a single flag, but its sentence must still be true.
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

    /// A due nudge belongs to Restructure's card, because it names one of that card's findings.
    /// `LensWorkspaceView.backlogNudge()` derives it from `scopedStructureFindings`, and the
    /// overview's Restructure arm counts the same `structureFindings` through the same `.inside`
    /// scope filter, so the folder in the sentence is one the pill above it counts. As a card of
    /// its own it would read as a second, headless subject.
    @Test func aDueNudgeAttachesToTheCardWhoseFindingItNames() {
        let reporting = Self.section(.restructure,
                                     .findings(count: 53, headline: "53 findings", examples: []))
        #expect(Self.overview([reporting], nudge: Self.nudge()).nudgeHost?.lens == .restructure)
        // And nothing attaches when nothing is due: the host is about the nudge, not about the card.
        #expect(Self.overview([reporting]).nudgeHost == nil)
    }

    /// A nudge with no host still draws, on a rung of its own. The two derivations are in step
    /// today, so this state is unreachable, but the failure it guards is silent (a time-sensitive
    /// line vanishing), and a defined answer costs one branch.
    @Test func theNudgeSurvivesLosingItsHost() throws {
        let clean = Self.section(.restructure, .clean)
        let page = Self.overview([clean], nudge: Self.nudge())
        #expect(page.nudgeHost == nil, "a clean Restructure is not a card to hang a nudge on")

        // And it reaches the pixels rather than only the model: the same page without a nudge draws
        // measurably less.
        let with = try #require(Self.render(page))
        let without = try #require(Self.render(Self.overview([clean])))
        let differing = PixelDiff.differingPixels(with, without, tolerance: 0.04)
        #expect(differing > 2000, "a homeless nudge drew nothing — it is lost, not relocated")
    }

    // MARK: Storage has a card

    /// Storage before its first analysis is a lens with a verb and a real answer to give, so it
    /// gets a card, not a line of grey footer text. It is still stranded (no ``OrganizePass``
    /// produces it), so the assertion is on what a stranded lens draws. `strandedCards` and
    /// `strandedLines` partition `strandedUnscanned`, so a lens can't fall out of both.
    @Test func aNeverAnalyzedStorageTakesACardAndNotAFootnote() {
        let page = Self.overview([Self.section(.storage, .notScanned)])
        #expect(page.strandedCards.contains { $0.lens == .storage },
                "Storage before its first analysis is still a footer line")
        #expect(!page.strandedLines.contains { $0.lens == .storage })
    }

    /// And a host that can't analyze still gets the line, not a dead card: a card offering a scan
    /// nothing can start is worse than a sentence saying it has not run.
    @Test func aStorageWithNoAnalyzerStaysAQuietLine() {
        let page = Self.overview([Self.section(.storage, .notScanned)], buildStorage: nil)
        #expect(page.strandedLines.contains { $0.lens == .storage })
        #expect(page.strandedCards.isEmpty)
    }

    /// The partition holds for every stranded lens: a lens in neither list would vanish from the
    /// screen, a failure with no visible symptom.
    @Test func everyStrandedLensIsDrawnExactlyOnce() {
        let sections = OrganizeLens.allCases.map { Self.section($0, .notScanned) }
        let page = Self.overview(sections, runnable: [])
        let drawn = Set(page.strandedCards.map(\.lens)).union(page.strandedLines.map(\.lens))
        #expect(drawn == Set(page.strandedUnscanned.map(\.lens)))
        #expect(Set(page.strandedCards.map(\.lens))
            .isDisjoint(with: Set(page.strandedLines.map(\.lens))))
    }

    // MARK: A card with nothing to show is not taller for it

    /// An empty content slot must not add 7pt of dead air to a card. `OverviewCard` separates
    /// heading from content by 7pt, and an empty `VStack` is still a view, so a slot built
    /// unconditionally takes that spacing: the difference between `if x { VStack { … } }` and
    /// `VStack { if x { … } }`. Renames and Restructure pass no rows, so this keeps card heights in
    /// step. Measured through the real cards, so the claim is about what the overview builds.
    @Test func aFindingsCardWithNoRowsIsNoTallerForIt() {
        let bare = Self.section(.renames, .findings(count: 126, headline: "126 to change",
                                                    examples: []))
        let withRows = Self.section(.renames, .findings(count: 126, headline: "126 to change",
                                                        examples: ["a.pdf → Finance"]))
        let bareHeight = Self.cardHeight(bare)
        let rowsHeight = Self.cardHeight(withRows)
        // Measured: 53pt correct, 60pt with the slot built unconditionally. 57 leaves four points
        // of margin either side, so a half-point of font metric can't flip it.
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
        let page = overview([section], buildStorage: nil, nudge: nudge)
        // The page's own 14pt padding top and bottom is the only other tenant with one section.
        let host = NSHostingView(rootView: AnyView(page.frame(width: 560)))
        return host.fittingSize.height - 28
    }

    // MARK: The surface is one surface

    /// A finding and an offer are drawn on the same surface. A tinted findings card would look like
    /// it came from a different app, to carry a signal the accent glyph tile and count pill already
    /// carry.
    ///
    /// The same lens is rendered reporting and not, and the card's fill is sampled at the leading
    /// edge where no content reaches. The card's top edge is found by scanning down, not hardcoded,
    /// so a spacing change doesn't break it but a tint still fails it.
    @Test func aFindingAndAnOfferAreDrawnOnTheSameSurface() throws {
        let reporting = try #require(Self.cardFill(
            [Self.section(.duplicates,
                          .findings(count: 722, headline: "722 groups",
                                    examples: ["clip.mp4 — 2 copies"]))]))
        let offer = try #require(Self.cardFill([Self.section(.duplicates, .notScanned)]))
        let delta = PixelProbe.distance(reporting, offer)
        #expect(delta < 0.02,
                "the reporting card's fill is \(reporting), the offer's \(offer) — one is tinted")
    }

    /// The probe must be able to fail: the glyph tile on the same two cards does differ, which is
    /// where the accent lives.
    @Test func theToneStillReachesTheGlyph() throws {
        let reporting = try #require(Self.glyphFill(
            [Self.section(.duplicates,
                          .findings(count: 722, headline: "722 groups", examples: []))]))
        let offer = try #require(Self.glyphFill([Self.section(.duplicates, .notScanned)]))
        let delta = PixelProbe.distance(reporting, offer)
        #expect(delta > 0.02,
                "a reporting glyph tile is indistinguishable from an offer's — nothing says work")
    }

    // MARK: The verbs land on one line

    /// Every card's main verb ends at the same x, including the one card that can be dismissed.
    /// Only pixels can say this: "the primary is drawn last" is a fact about an array, and says
    /// nothing about where a control lands once a × is drawn beside it. A trailing × would push the
    /// nudge's "Set up…" inboard of every other primary.
    ///
    /// Measured per card, because two things sit further right than a button and neither is one:
    /// the card's hairline, and the button's rounded corners. The walk starts inside the card to
    /// skip the border, and takes each card's furthest reach rather than every row's, since a
    /// capsule's flat trailing edge is the furthest right it goes; comparing every row would
    /// measure the curves.
    @Test func everyCardsPrimaryEndsOnTheSameLine() throws {
        try Self.assertVerbsLineUp(width: Self.canvas.width, scale: 1)
    }

    /// And they still do at every text size, on a pane narrow enough to squeeze them. The buttons
    /// are `.fixedSize()` and titles wrap, so a card under pressure grows taller. At 135% on a
    /// 420pt pane the longest heading shares its row with the longest verb; if the trailing cluster
    /// compressed instead, the verbs would stop agreeing about where they end. The rail tests
    /// itself the same way (`OrganizeRailTests` runs its width model over `FontSize.allCases`).
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
        // Each pixel is read as one 32-bit word, and `colorAt` is asked once per distinct word (a
        // render has under 150 colours). Calling `colorAt` per pixel costs millions of calls a
        // render and can hold the main thread for minutes under load.
        let data = try #require(rep.bitmapData.map(UnsafeRawPointer.init))
        try #require(rep.bitsPerPixel == 32 && !rep.isPlanar,
                     "the render is not 32-bit interleaved, so a pixel cannot be read as one word")
        let bytesPerRow = rep.bytesPerRow
        var verdicts: [UInt32: Bool] = [:]
        var last: (key: UInt32, verdict: Bool)?

        /// Whether this pixel is button fill rather than text or a hairline. A button is a solid
        /// capsule in a mid tone, light grey over the light ground, so the colour rules out text,
        /// whose strokes are near-black, and the run length below rules out a card's one-pixel
        /// hairline and a letter's antialiased edge. Keying on "differs from the ground at all"
        /// would read wrapped headings as controls on a narrow pane.
        ///
        /// Light mode only, which `render` pins: the band is stated against a light ground.
        func isButtonFill(_ x: Int, _ y: Int) -> Bool {
            let key = data.loadUnaligned(fromByteOffset: y * bytesPerRow + x * 4, as: UInt32.self)
            if let last, last.key == key { return last.verdict }
            if let verdict = verdicts[key] { last = (key, verdict); return verdict }
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            let delta = max(abs(c.redComponent - ground.redComponent),
                            max(abs(c.greenComponent - ground.greenComponent),
                                abs(c.blueComponent - ground.blueComponent)))
            let verdict = delta > 0.02 && delta < 0.35
            verdicts[key] = verdict
            last = (key, verdict)
            return verdict
        }
        // A capsule is at least this wide even for the shortest verb on the page; no glyph is.
        let solid = Int(8 * pixels)
        // Start inside the card: the page insets every card by 14pt, so anything at or beyond that
        // is the card's own edge, not a control on it.
        let from = Int((width - 18) * pixels)
        // Rows whose rightmost button reaches the gutter: every card's action row and nothing else,
        // since this fixture draws no ledger strip (`Ledger()` is empty) and a count pill always
        // sits left of its verbs.
        let gutter = width - 140

        /// The trailing edge of the rightmost button on this row, in points. The walk gives up once
        /// it is past the gutter with no button under way, since any it found further on would end
        /// short of the gutter.
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
                    if CGFloat(x + 1) / pixels <= gutter { return nil }
                }
            }
            return nil
        }
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
        // Max per band, not per row: a capsule's rounded corners reach less far than its flat edge.
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
    /// leading edge inside it, left of the glyph tile, so no content can reach the probe.
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
            return PixelProbe.distance(c, ground) > 0.008
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
        // Tall enough that a 135% render still fits every card; a page that overflowed would clip
        // the last card's verb and the probe would not see it.
        let size = CGSize(width: width ?? canvas.width, height: canvas.height * (1 + fontScale))
        let mounted = ReviewLensHost.mount(page.environment(\.appFontScale, fontScale), size: size, passes: 2)
        return withExtendedLifetime(mounted.window) { PixelProbe.render(mounted.host, mounted.host.bounds) }
    }
}
