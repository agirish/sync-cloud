import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The Scaffolded card's Update the Survey button. The card states a wait ("the survey hasn't
/// caught up yet, so this stays until it is updated"), and the button is what ends it.
@MainActor
@Suite struct RestructureSurveyRefreshTests {

    private static func backlog() -> StructureFinding {
        StructureFinding(kind: .backlog, family: "Health/Dental",
                         subject: "Health/Dental/2026",
                         detail: .backlog(scaffold: ["Claims"], looseFiles: 3))
    }

    /// The help says what a reader wouldn't guess: this replaces the hand-built survey with a
    /// derived one, as applying a plan does.
    @Test func theHelpSaysItReplacesTheSurvey() {
        let help = RestructureLens.refreshSurveyHelp
        #expect(help.contains("Re-reads the tree"))
        #expect(help.contains("replaces the survey"),
                "a sanctioned change is only sanctioned if it is stated")
        #expect(help.contains("applying a plan does"),
                "naming the precedent is what makes it not a surprise")
    }

    /// The card's sentence stands: the button ends the wait, it doesn't deny it.
    @Test func theScaffoldedSentenceIsUnchanged() {
        #expect(RestructureLens.scaffoldLandedText.contains("hasn’t caught up"))
        #expect(RestructureLens.scaffoldLandedText.contains("until it is updated"))
    }

    private static func lens(refusal: (subject: String, sentence: String)?,
                             scaffolded: Bool = true,
                             refreshing: Bool = false) -> RestructureLens {
        RestructureLens(
            findings: [Self.backlog()], hasProfile: true, folderCount: 10,
            accent: .blue, onReveal: { _ in },
            scaffoldedSubjects: scaffolded ? ["Health/Dental/2026"] : [],
            hasReviewed: true,
            isRefreshing: refreshing,
            onRefreshSurvey: { _ in },
            refreshSurveyRefusal: refusal)
    }

    /// A refusal is a sentence on the card, not a queue: the guards are the landing's, so the
    /// honest answer is "wait and press it again". Read off the drawn pixels, so a dropped refusal
    /// fails.
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

    /// Keyed by card: a refusal carrying another subject leaves this card exactly as it was, or two
    /// Scaffolded cards would both show a sentence one never asked for.
    @Test func aRefusalForAnotherCardLeavesThisOneAlone() throws {
        let none = try #require(RestructureRender.raster(
            Self.lens(refusal: nil), width: 640, height: 300))
        let elsewhere = try #require(RestructureRender.raster(
            Self.lens(refusal: ("Work/Benefits/2026", "Wait for the scan.")),
            width: 640, height: 300))
        #expect(RestructureRender.differingPixels(none, elsewhere) == 0,
                "another card's refusal draws nothing here")
    }

    /// The button exists only on a card that is waiting. A backlog finding whose scaffold hasn't
    /// landed offers the scaffold instead; a refresh there would re-derive a survey that isn't
    /// stale.
    @Test func theButtonBelongsToTheScaffoldedStateAlone() throws {
        let text = try SourceText.fileExplorer("RestructureLens.swift")
        let landed = try #require(text.range(of: "if scaffoldedSubjects.contains(finding.subject)"))
        let elseBranch = try #require(text.range(of: "} else if !scaffold.isEmpty, let onScaffold {",
                                                 range: landed.lowerBound..<text.endIndex))
        let branch = text[landed.lowerBound..<elseBranch.lowerBound]
        #expect(SourceText.normalized(String(branch))
                    .contains(SourceText.normalized("{ onRefreshSurvey(finding.subject) }")),
                "the button lives in the scaffolded branch")
        #expect(!SourceText.normalized(String(text[elseBranch.lowerBound...].prefix(600)))
                    .contains(SourceText.normalized("onRefreshSurvey(finding.subject)")),
                "and not in the not-yet-scaffolded one")
    }

    /// The host runs the manager's re-derive rather than a walk of its own, and clears the previous
    /// refusal before trying again.
    @Test func theHostAsksTheManagerToReDerive() throws {
        let host = try SourceText.fileExplorer("LensWorkspaceView.swift")
        #expect(host.contains("await syncManager.refreshDerivedProfile()"))
        #expect(host.contains("refreshSurveyRefusal = nil"),
                "a stale refusal must not survive the next press")
    }

    /// Every call site reports success, not only the refusal: a multi-second walk that finishes in
    /// silence reads as a button that did nothing. Asserted at the call sites, not on
    /// `SurveyRefreshOutcome`, because the type can't make anyone render it.
    @Test func everyRefreshCallSiteSaysSomethingWhenItWorked() throws {
        let host = try SourceText.fileExplorer("LensWorkspaceView.swift")
        // Both closures destructure the outcome and both mention the success branch.
        let calls = host.components(separatedBy: "await syncManager.refreshDerivedProfile()")
        #expect(calls.count == 3, "expected exactly two call sites, found \(calls.count - 1)")
        for (index, tail) in calls.dropFirst().enumerated() {
            let window = String(tail.prefix(600))
            // `outcome.banner` says success too (`SurveyRefreshOutcome.banner`).
            #expect(window.contains(".success(outcome.sentence)") || window.contains("syncManager.banner = outcome.banner"),
                    "call site \(index + 1) never reports a successful refresh — the path that works is the one that says nothing")
        }
    }

    /// Each control that starts the walk is disabled while it runs, greys, and says so; otherwise a
    /// button that looks idle gets pressed again, collecting a refusal per press. Scanned per
    /// control, so one keeping its busy state can't vouch for another.
    @Test func theRefreshControlsShowTheyAreBusy() throws {
        let lens = try SourceText.fileExplorer("RestructureLens.swift")
        #expect(lens.contains("var isRefreshing: Bool"),
                "the lens cannot show a busy state it is never told about")
        let busy = [
            "Button(isRefreshing ? \"Updating the Survey…\" : \"Update the Survey\")",
            ".foregroundStyle(isRefreshing ? AnyShapeStyle(.secondary)",
            ".disabled(isRefreshing)",
            "\"Re-reading the tree now — this takes a few seconds.\"",
        ]
        for (control, opening) in [("the Scaffolded card", "if scaffoldedSubjects.contains(finding.subject)"),
                                   ("the stale-survey note", "if stale, let onUpdateSurvey")] {
            let block = SourceText.normalized(try SourceText.block(opening: opening, in: lens))
            for piece in busy {
                #expect(block.contains(SourceText.normalized(piece)),
                        "\(control)'s Update the Survey lacks \(piece)")
            }
        }
        #expect(lens.contains("isBusy: isRefreshing"),
                "the setup card's secondary action must carry the same busy state")

        // And the host must actually pass the engine's own flag, not a local that can drift.
        let host = try SourceText.fileExplorer("LensWorkspaceView.swift")
        #expect(host.contains("isRefreshing: syncManager.restructureLandingInProgress"),
                "the button's enabled state must be the engine's guard, or the two disagree")
    }

    /// Drawn, not only read: the Scaffolded card looks different while a refresh runs, and a card
    /// without the button looks the same either way, so the difference is the button's.
    @Test func theScaffoldedButtonDrawsItsBusyState() throws {
        func render(scaffolded: Bool, refreshing: Bool) throws -> NSBitmapImageRep {
            try #require(RestructureRender.raster(
                Self.lens(refusal: nil, scaffolded: scaffolded, refreshing: refreshing),
                width: 640, height: 300))
        }
        let idle = try render(scaffolded: true, refreshing: false)
        let busy = try render(scaffolded: true, refreshing: true)
        #expect(RestructureRender.inkedPixels(idle) > 0, "the card drew something at all")
        #expect(RestructureRender.differingPixels(idle, busy) > 200,
                "Update the Survey must look busy while the survey is updating")
        #expect(RestructureRender.differingPixels(try render(scaffolded: false, refreshing: false),
                                                  try render(scaffolded: false, refreshing: true)) == 0,
                "nothing else on the card reacts to a refresh")
    }
}
