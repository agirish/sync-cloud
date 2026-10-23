import Foundation
import Testing
@testable import FileExplorer

/// Which states the Organize strip appears for, and whose words it uses.
@Suite struct DocumentSurveyStripTests {

    /// The three states that are about a run in flight.
    @Test func theStripIsShownForARunInFlight() {
        #expect(DocumentSurveyStrip.isShown(for: .running(done: 4, total: 90, folder: "Finance",
                                                          secondsRemaining: 60, pause: nil)))
        #expect(DocumentSurveyStrip.isShown(for: .finishing(done: 90)))
        #expect(DocumentSurveyStrip.isShown(for: .interrupted(done: 12, total: 90)))
    }

    /// **An offer is not a run**, and a receipt is not either. A strip on every lens announcing a
    /// finished job would be a banner nobody can dismiss, and the offer needs the room the card has
    /// to say what it costs.
    @Test func theStripIsHiddenForOffersAndReceipts() {
        #expect(!DocumentSurveyStrip.isShown(for: .offered(documents: 6_140)))
        #expect(!DocumentSurveyStrip.isShown(for: .finished(summary: "Read 90 documents.",
                                                            unreadableTypes: 0)))
        #expect(!DocumentSurveyStrip.isShown(for: .settled(folders: 12, lastRead: nil)))
        #expect(!DocumentSurveyStrip.isShown(for: nil))
    }

    /// The strip quotes the card rather than wording the same run a second time.
    @Test func theWordsAreTheCardsOwn() {
        let state = DocumentSurveyCardState.running(done: 140, total: 6_140, folder: "Finance",
                                                    secondsRemaining: 900, pause: nil)
        #expect(DocumentSurveyCardText.title(for: state).contains("140"))
        #expect(!DocumentSurveyCardText.detail(for: state).isEmpty)
    }

    /// **And the card's verbs: never one the card does not offer in the same state**, under the
    /// card's own tooltip. The interrupted strip had a Stop the card does not — and with nothing
    /// running, `stopDocumentSurvey()` had no run to stop, so the button did nothing.
    @MainActor @Test func everyVerbIsOneTheCardOffers() {
        let states: [DocumentSurveyCardState] = [
            .running(done: 4, total: 90, folder: "Finance", secondsRemaining: 60, pause: nil),
            .running(done: 4, total: 90, folder: nil, secondsRemaining: nil,
                     pause: .init(sentence: "Paused.", resumesOnItsOwn: false)),
            .running(done: 4, total: 90, folder: nil, secondsRemaining: nil,
                     pause: .init(sentence: "Paused — the Mac is running hot.", resumesOnItsOwn: true)),
            .finishing(done: 90),
            .interrupted(done: 12, total: 90),
            .interrupted(done: 90, total: 90),
        ]
        for state in states {
            let strip = DocumentSurveyStrip(state: state, accent: .blue,
                                            onResume: {}, onPause: {}, onStop: {})
            let card = DocumentSurveyCard(state: state, accent: .blue, onStart: {},
                                          onStartOver: {}, onResume: {}, onPause: {}, onStop: {})
            let cards = Set(card.verbs.map { "\($0.title) — \($0.help ?? "no tooltip")" })
            for verb in strip.verbs.map({ "\($0.title) — \($0.help ?? "no tooltip")" }) {
                #expect(cards.contains(verb), "\(state): the strip offers “\(verb)”, the card \(cards.sorted())")
            }
        }
    }

    /// **Interrupted, the strip offers Resume and nothing else.** Nothing is running, so there is
    /// nothing to stop; and *Start over* throws hours of reading away behind a question, which
    /// belongs on the card — the overview, where there is room to say what it costs — not on a
    /// line drawn across every lens.
    @MainActor @Test func theInterruptedStripOffersOnlyResume() {
        let strip = DocumentSurveyStrip(state: .interrupted(done: 12, total: 90), accent: .blue,
                                        onResume: {}, onPause: {}, onStop: {})
        #expect(strip.verbs.map(\.title) == ["Resume"])
    }
}

/// The strip is drawn where the workspace's header ends, on every lens.
///
/// **A source scan, because a view that is never instantiated is a view no unit test can miss.**
/// `DocumentSurveyStripTests` above proves the strip decides correctly which states it appears
/// for; it says nothing at all about whether anything asks it. The whole feature is that the line
/// shows up on the five lenses that do not carry the card, and that is a property of the call
/// site.
@Suite struct DocumentSurveyStripCallSiteTests {

    private static func lensWorkspaceSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read LensWorkspaceView.swift — this scan would be vacuous")
        try #require(source.contains("private var sourceBar"),
                     "that is not the lens workspace — every check below would be vacuous")
        return source
    }

    /// It is drawn, and it is drawn once.
    @Test func theWorkspaceDrawsTheStrip() throws {
        let source = try Self.lensWorkspaceSource()
        #expect(source.components(separatedBy: "DocumentSurveyStrip(").count - 1 == 1,
                "the strip is drawn \(source.components(separatedBy: "DocumentSurveyStrip(").count - 1) times")
        #expect(source.contains("DocumentSurveyStrip.isShown(for:"),
                "the workspace decides for itself which states to draw it in, rather than asking the strip")
    }

    /// **Below the header card, above the source bar.** The header is pinned at 81pt by its own
    /// test and every lens lines its lower edge up with the file pane's; a strip inserted above it
    /// would move that edge on exactly the lenses a survey is running on.
    @Test func theStripSitsBetweenTheHeaderAndTheSourceBar() throws {
        let source = try Self.lensWorkspaceSource()
        let header = try #require(source.range(of: "lensHeaderCard(rows: rows, counts: counts"))
        let strip = try #require(source.range(of: "DocumentSurveyStrip("))
        let sourceBar = try #require(source.range(of: "if showSourcePicker { sourceBar }"))
        #expect(header.upperBound < strip.lowerBound, "the strip is drawn above the header card")
        #expect(strip.upperBound < sourceBar.lowerBound, "the strip is drawn below the source bar")
    }

    /// Its verbs are the ones the workspace already holds, not a second way to reach the survey.
    @Test func theStripIsWiredToTheWorkspacesOwnVerbs() throws {
        let source = try Self.lensWorkspaceSource()
        for verb in ["onResume: onResumeDocumentSurvey", "onPause: onPauseDocumentSurvey",
                     "onStop: onStopDocumentSurvey"] {
            #expect(source.contains(verb), "the strip is missing \(verb)")
        }
    }

    /// **The card's Start over reaches the verb that discards**, through the workspace to the
    /// overview — the card's own test cannot see this wiring, and `onStart` in its place resumes.
    @Test func theCardsStartOverIsWiredToTheVerbThatDiscards() throws {
        let workspace = try Self.lensWorkspaceSource()
        #expect(workspace.contains("onStartDocumentSurveyOver: onStartDocumentSurveyOver"))
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/OrganizeOverview.swift")
        let overview = try #require(try? String(contentsOf: url, encoding: .utf8),
                                    "cannot read OrganizeOverview.swift — this scan would be vacuous")
        #expect(overview.contains("onStartOver: onStartDocumentSurveyOver"))
    }
}
