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
        let states: [OrganizeOverviewState] = [
            .findings(count: 7, headline: "7 groups", examples: ["a — 2 copies"]),
            .receipt(headline: "214.6 GB total", detail: "Analyzed Tuesday · ~/Documents"),
            .notScanned]
        for lens in OrganizeLens.allCases where lens.carriesBadge || lens == .storage {
            for state in states {
                let section = Self.section(lens, state)
                let actions = Self.overview([section]).actions(for: section)
                #expect(actions.filter { $0.rank == .primary }.count <= 1,
                        "\(lens.title) in \(state) offers two primaries")
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
        // And the settled receipt's one verb IS the primary — the specific control the complaint
        // named, which used to be the only unshaped button on the screen.
        let settled = DocumentSurveyCard(state: .settled(folders: 2_309, lastRead: nil),
                                         accent: .blue, onUpdate: {})
        #expect(settled.verbs.map(\.rank) == [.primary])
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
        let rep = try #require(Self.render(page))
        let scale = CGFloat(rep.pixelsWide) / Self.canvas.width
        let ground = try #require(rep.colorAt(x: rep.pixelsWide - 3, y: rep.pixelsHigh - 3))
        func differs(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            return max(abs(c.redComponent - ground.redComponent),
                       max(abs(c.greenComponent - ground.greenComponent),
                           abs(c.blueComponent - ground.blueComponent))) > 0.02
        }
        // Start inside the card: the page insets every card by 14pt, so anything at or beyond that
        // is the card's own edge and not a control on it.
        let from = Int((Self.canvas.width - 18) * scale)
        func trailingEdge(_ y: Int) -> CGFloat? {
            var run = 0
            for x in stride(from: from, through: 0, by: -1) {
                run = differs(x, y) ? run + 1 : 0
                if run == 3 { return CGFloat(x + 3) / scale }
            }
            return nil
        }
        // Rows whose rightmost mark is out in the button gutter. Nothing else on the page reaches
        // there, so a contiguous run of them is one card's action row.
        let gutter = Self.canvas.width - 120
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
        let reaches = bands.filter { $0.count > 4 }.compactMap { $0.max() }
        // Restructure, the duplicate pass, Storage, the nudge and the inbox all carry a verb.
        #expect(reaches.count >= 5,
                "found \(reaches.count) action rows — the probe is not seeing every card's verb")
        let spread = (reaches.max() ?? 0) - (reaches.min() ?? 0)
        #expect(spread < 1.5,
                "the cards' verbs end between \(Int(reaches.min() ?? 0)) and \(Int(reaches.max() ?? 0))pt — they do not line up")
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

    private static func render(_ page: OrganizeOverview) -> NSBitmapImageRep? {
        let subject = page
            .frame(width: canvas.width, height: canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: canvas)
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
