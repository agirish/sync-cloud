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
}
