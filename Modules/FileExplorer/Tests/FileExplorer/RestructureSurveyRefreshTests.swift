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

    private static func lens(refusal: (subject: String, sentence: String)?,
                             scaffolded: Bool = true) -> RestructureLens {
        RestructureLens(
            findings: [Self.backlog()], hasProfile: true, folderCount: 10,
            accent: .blue, onReveal: { _ in },
            scaffoldedSubjects: scaffolded ? ["Health/Dental/2026"] : [],
            hasReviewed: true,
            onRefreshSurvey: { _ in },
            refreshSurveyRefusal: refusal)
    }

    /// A refusal is a sentence on the card, not a queue: the guards are the landing's, so the
    /// honest answer is "wait and press it again".
    ///
    /// Read off the drawn pixels rather than a `fittingSize` closer — with a width assertion this
    /// passed just as happily when the refusal was dropped on the floor.
    @Test func aRefusalRendersOnTheCardItCameFrom() throws {
        let without = try #require(RestructureRender.raster(
            Self.lens(refusal: nil), width: 640, height: 300))
        let with = try #require(RestructureRender.raster(
            Self.lens(refusal: ("Health/Dental/2026",
                                "Wait for the duplicate scan to finish first.")),
            width: 640, height: 300))
        #expect(RestructureRender.inkedPixels(without) > 0, "the card drew something at all")
        #expect(RestructureRender.differingPixels(without, with) > 200,
                "the refusal sentence is on the card")
    }

    /// **Keyed by card.** The refusal belongs to the card that asked; a refusal carrying another
    /// subject must leave this one exactly as it was, or two Scaffolded cards would both show a
    /// sentence one of them never asked for.
    @Test func aRefusalForAnotherCardLeavesThisOneAlone() throws {
        let none = try #require(RestructureRender.raster(
            Self.lens(refusal: nil), width: 640, height: 300))
        let elsewhere = try #require(RestructureRender.raster(
            Self.lens(refusal: ("Work/Benefits/2026", "Wait for the scan.")),
            width: 640, height: 300))
        #expect(RestructureRender.differingPixels(none, elsewhere) == 0,
                "another card's refusal draws nothing here")
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

    /// **Every call site reports the SUCCESS path, not only the refusal.**
    ///
    /// This is the bug he hit an hour after v5.0 shipped: "nothing happens when I click Update
    /// the Survey". It had happened — four times, because he pressed it four times — and the
    /// survey really did go from 3013 folders to 5021. The refresh returned `nil` on success and
    /// both call sites read `if let refusal = … { banner }`, so the working path had no branch at
    /// all. A five-second tree walk finished in silence.
    ///
    /// Asserted at the call sites rather than on `SurveyRefreshOutcome`, because the type cannot
    /// make anyone render it — the previous type could not either, and that was the whole defect.
    @Test func everyRefreshCallSiteSaysSomethingWhenItWorked() throws {
        let host = try Self.hostSource()
        // Both closures destructure the outcome and both mention the success branch.
        let calls = host.components(separatedBy: "await syncManager.refreshDerivedProfile()")
        #expect(calls.count == 3, "expected exactly two call sites, found \(calls.count - 1)")
        for (index, tail) in calls.dropFirst().enumerated() {
            let window = String(tail.prefix(600))
            #expect(window.contains(".success(outcome.sentence)"),
                    "call site \(index + 1) never reports a successful refresh — the path that works is the one that says nothing")
        }
    }

    /// The control that starts the walk is disabled while it runs, and says so. Without this the
    /// only response to a button that looks dead is to press it again — which is what produced
    /// eight `Another reorganisation is landing right now` refusals in one millisecond.
    @Test func theRefreshControlsShowTheyAreBusy() throws {
        let lens = try Self.lensSource()
        #expect(lens.contains("var isRefreshing: Bool"),
                "the lens cannot show a busy state it is never told about")
        #expect(lens.contains("Button(isRefreshing ? \"Rescanning…\" : \"Rescan\")"),
                "Rescan must say when it is already rescanning")
        #expect(lens.contains(".disabled(isRefreshing)"),
                "Rescan must refuse the second press rather than collecting a refusal for it")
        #expect(lens.contains("isBusy: isRefreshing"),
                "the setup card's secondary action must carry the same busy state")

        // And the host must actually pass the engine's own flag, not a local that can drift.
        let host = try Self.hostSource()
        #expect(host.contains("isRefreshing: syncManager.restructureLandingInProgress"),
                "the button's enabled state must be the engine's guard, or the two disagree")
    }

    /// The positive control for the two source scans above: they read real files with real
    /// content, so an empty result means absence rather than a path that resolved nowhere.
    @Test func theSourceScansAreReadingRealFiles() throws {
        #expect(try Self.hostSource().contains("struct LensWorkspaceView"))
        #expect(try Self.lensSource().contains("struct RestructureLens"))
    }

    static func hostSource() throws -> String {
        try String(contentsOf: sourcesDirectory.appendingPathComponent("LensWorkspaceView.swift"),
                   encoding: .utf8)
    }

    static func lensSource() throws -> String {
        try String(contentsOf: sourcesDirectory.appendingPathComponent("RestructureLens.swift"),
                   encoding: .utf8)
    }

    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer")
    }
}
