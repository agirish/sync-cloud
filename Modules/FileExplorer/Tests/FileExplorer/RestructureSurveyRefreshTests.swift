import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §5.7's Scaffolded card, given the button its own sentence promised (proposal O12).
///
/// The card states a wait — "the survey hasn't caught up yet, so this stays until it is
/// updated" — and until now nothing on it ended that wait.
@MainActor
@Suite struct RestructureSurveyRefreshTests {

    private static func backlog() -> StructureFinding {
        StructureFinding(kind: .backlog, family: "Health/Dental",
                         subject: "Health/Dental/2026",
                         detail: .backlog(scaffold: ["Claims"], looseFiles: 3))
    }

    /// The help says the part a reader would not guess: this replaces the hand-built survey with
    /// a derived one, which is the first thing a scaffold causes to do that.
    @Test func theHelpSaysItReplacesTheSurvey() {
        let help = RestructureLens.refreshSurveyHelp
        #expect(help.contains("Re-reads the tree"))
        #expect(help.contains("replaces the survey"),
                "a sanctioned change is only sanctioned if it is stated")
        #expect(help.contains("applying a plan does"),
                "naming the precedent is what makes it not a surprise")
    }

    /// The card still says what it said — the button ENDS the wait, it does not deny it.
    @Test func theScaffoldedSentenceIsUnchanged() {
        #expect(RestructureLens.scaffoldLandedText.contains("hasn’t caught up"))
        #expect(RestructureLens.scaffoldLandedText.contains("until it is updated"))
    }

    /// A refusal is a sentence on the card, not a queue: the guards are the landing's, so the
    /// honest answer is "wait and press it again".
    @Test func aRefusalRendersOnTheCardItCameFrom() {
        let lens = RestructureLens(
            findings: [Self.backlog()], hasProfile: true, folderCount: 10,
            accent: .blue, onReveal: { _ in },
            scaffoldedSubjects: ["Health/Dental/2026"], hasReviewed: true,
            onRefreshSurvey: {},
            refreshSurveyRefusal: "Wait for the duplicate scan to finish first.")
        let hosting = NSHostingView(rootView: lens.frame(width: 640, height: 300))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }

    /// **The button only exists on a card that is waiting.** A backlog finding whose scaffold has
    /// not landed offers the scaffold instead, and rendering the refresh there would offer to
    /// re-derive a survey that is not stale.
    @Test func theButtonBelongsToTheScaffoldedStateAlone() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructureLens.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let landed = try #require(text.range(of: "if scaffoldedSubjects.contains(finding.subject)"))
        let elseBranch = try #require(text.range(of: "} else if !scaffold.isEmpty, let onScaffold {",
                                                 range: landed.lowerBound..<text.endIndex))
        let branch = text[landed.lowerBound..<elseBranch.lowerBound]
        #expect(branch.contains("Update the survey now"),
                "the button lives in the scaffolded branch")
        #expect(!text[elseBranch.lowerBound...].prefix(600).contains("Update the survey now"),
                "and not in the not-yet-scaffolded one")
    }

    /// The host runs the manager's re-derive rather than a second walk of its own, and clears the
    /// previous refusal before trying again.
    @Test func theHostAsksTheManagerToReDerive() throws {
        let host = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift"),
            encoding: .utf8)
        #expect(host.contains("await syncManager.refreshDerivedProfile()"))
        #expect(host.contains("refreshSurveyRefusal = nil"),
                "a stale refusal must not survive the next press")
    }
}
