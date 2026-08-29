import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The checklist the plan sheet shows while a landing runs (proposal O7).
@MainActor
@Suite struct RestructureApplyProgressSurfaceTests {

    /// Done, doing, still to come — a landing only moves forward, so a stage behind the current
    /// one is finished and one ahead has not started.
    @Test func theSymbolsSayWhereTheLandingIs() {
        let symbol = RestructurePlanSheet.stageSymbol
        #expect(symbol(.guards, .operations) == "checkmark.circle.fill")
        #expect(symbol(.operations, .operations) == "circle.dotted")
        #expect(symbol(.verify, .operations) == "circle")
        #expect(symbol(.artifacts, .artifacts) == "circle.dotted",
                "the last stage is still in progress while it is the current one")
    }

    /// Every symbol has to be real, or a stage renders as a blank square.
    @Test func everySymbolIsARealSFSymbol() {
        for stage in RestructureApplyProgress.Stage.allCases {
            for current in RestructureApplyProgress.Stage.allCases {
                let name = RestructurePlanSheet.stageSymbol(stage, current: current)
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                        "\(name) is not a real symbol")
            }
        }
    }

    /// **The checklist only exists while a landing does.** A progress value outliving its
    /// landing would leave the sheet showing steps for work that finished or refused, so the
    /// sheet renders it only when the manager is publishing one.
    @Test func theSheetShowsTheChecklistOnlyWhileApplying() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructurePlanSheet.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("if let applyProgress { progressChecklist(applyProgress) }"))

        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sync/Sources/Sync/FileSyncManager+RestructureApply.swift")
        let engineText = try String(contentsOf: engine, encoding: .utf8)
        #expect(engineText.contains("restructureApplyProgress = nil"),
                "the value has to be cleared however the landing returns")
        // Every stage the type declares is actually published by the engine — a stage that never
        // arrives would sit greyed forever while the landing ran past it.
        for stage in RestructureApplyProgress.Stage.allCases {
            #expect(engineText.contains("RestructureApplyProgress(stage: .\(stage))")
                        || engineText.contains("stage: .\(stage),"),
                    "nothing publishes .\(stage)")
        }
    }

    /// The host hands the manager's published value straight through — a sheet holding its own
    /// copy could show a stage the engine never reached.
    @Test func theHostPassesTheManagersProgress() throws {
        let host = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift"),
            encoding: .utf8)
        #expect(host.contains("applyProgress: syncManager.restructureApplyProgress"))
    }

    /// The sheet renders mid-landing, at a stage with a count and at one without.
    @Test func theSheetRendersItsChecklist() {
        for progress in [RestructureApplyProgress(stage: .operations, opsDone: 12, opsTotal: 38),
                         RestructureApplyProgress(stage: .inverse)] {
            let finding = StructureFinding(
                family: "F",
                schemes: [.init(vocabulary: ["forms"], members: ["2013"]),
                          .init(vocabulary: ["federal"], members: ["2014"])])
            let tree = RestructureTreeView(
                childFolders: { ["F": ["2013", "2014"], "F/2013": ["Federal"],
                                 "F/2014": ["Forms"]][$0] ?? [] },
                files: { _ in [] }, fileCount: { _ in 0 })
            let sheet = RestructurePlanSheet(
                finding: finding, family: "F", members: ["2013", "2014"], tree: tree,
                profileId: "p", accent: .blue,
                onExport: { _, _ in .saved(filename: "f.json") },
                applyProgress: progress, onClose: {})
            let hosting = NSHostingView(rootView: sheet.frame(width: 620, height: 760))
            hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0)
        }
    }
}
