import Foundation
import Sync
import Testing
@testable import FileExplorer

/// *Undo this reorganisation* asks before it runs a landing's inverse, and says what happened after.
///
/// **Both surfaces used to call the engine directly**: a plain text link on the Applied card and an
/// Organize menu item each ran an inverse that can move hundreds of files, with no question and no
/// redo — and a success left no banner, so from the menu the window said nothing at all.
@MainActor
@Suite struct ReorganisationUndoTests {

    private static func record(family: String = "Tax", summary: String? = "2 renames · 14 moved")
        -> RestructureStore.AppliedRecord {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m1", createdAt: "t", family: family, kind: .shape,
            actions: [.init(action: .renameDir, src: "Tax/A", dst: "Tax/B", filesCarried: 1)])
        return RestructureStore.AppliedRecord(
            manifest: manifest, inverse: manifest.inverse, at: "2026-08-28T09:00:00",
            created: 0, skipped: 0, appliedUnderProfileId: "p", summary: summary)
    }

    // MARK: The question

    @Test func theQuestionNamesTheFamilyAndWhatTheLandingDid() {
        let q = ReorganisationUndo.question(for: Self.record())
        #expect(q.title == "Undo the reorganisation of “Tax”?")
        #expect(q.detail.contains("2 renames · 14 moved"), "the person can't see what is reversed")
        #expect(q.detail.contains("not ⌘Z"))
        // The engine empties the whole session ⌘Z stack, so the question says so.
        #expect(q.detail.contains("clears Edit ▸ Undo"), "the question hides that ⌘Z history goes")
    }

    @Test func aRootLandingIsNamedAsTheTree() {
        #expect(ReorganisationUndo.question(for: Self.record(family: ".")).title
                == "Undo the reorganisation across the tree?")
    }

    // MARK: The banner

    @Test func aCleanUndoSaysSo() {
        var outcome = FileSyncManager.RestructureApplyOutcome()
        outcome.renamed = 2
        outcome.filesMoved = 14
        let banner = ReorganisationUndo.banner(after: outcome)
        #expect(banner.severity == .success)
        #expect(banner.message == "Reorganisation undone — 2 renames · 14 moved.")
    }

    @Test func aRefusalAndAPartialUndoAreWarnings() {
        var refused = FileSyncManager.RestructureApplyOutcome()
        refused.refusal = "A later reorganisation sits on top of this one."
        let refusal = ReorganisationUndo.banner(after: refused)
        #expect(refusal.severity == .warning)
        #expect(refusal.message == "A later reorganisation sits on top of this one.")

        var partial = FileSyncManager.RestructureApplyOutcome()
        partial.filesMoved = 3
        partial.skipped = ["Tax/B/x.pdf had moved on"]
        let banner = ReorganisationUndo.banner(after: partial)
        #expect(banner.severity == .warning, "a partial undo read as a clean one")
        #expect(banner.message.contains("1 skipped"))
    }

    // MARK: The run

    private func manager(holding record: RestructureStore.AppliedRecord) throws -> (FileSyncManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reorg-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.recordApplied(record), "premise: the ledger took the record")
        let manager = FileSyncManager()
        manager.restructureStore = store
        // A survey that names its folder, so nothing refuses before the question: the engine's
        // up-front checks pass, and it refuses only past the question, on the missing profiles
        // directory.
        manager.filingFolderProfile = FolderProfile(profileId: "p", root: dir.path, folders: [:],
                                                    personTokens: [])
        #expect(manager.restructureLandingBlocker == nil, "premise: nothing blocks the undo up front")
        return (manager, dir)
    }

    /// Declining runs nothing and says nothing.
    @Test func declinedRunsNothing() async throws {
        let (manager, dir) = try manager(holding: Self.record())
        defer { try? FileManager.default.removeItem(at: dir) }
        var asked: [String] = []

        await ReorganisationUndo.run(manifestId: "m1", on: manager) { title, _ in
            asked.append(title); return false
        }

        #expect(asked == ["Undo the reorganisation of “Tax”?"], "the undo ran without asking")
        #expect(manager.restructureStore?.applied.first?.undoneAt == nil)
        #expect(manager.banner == nil)
    }

    /// **It asked even when the engine would refuse at once.** With a scan running, the question
    /// went up and a Yes was refused; now the refusal is the answer and nothing is asked.
    @Test func aBlockedUndoSaysWhyWithoutAsking() async throws {
        let (manager, dir) = try manager(holding: Self.record())
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.isFindingDuplicates = true
        var asked = 0

        await ReorganisationUndo.run(manifestId: "m1", on: manager) { _, _ in
            asked += 1; return true
        }

        #expect(asked == 0, "the question went up over an undo the engine refuses")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message == "Wait for the duplicate scan to finish first.")
        #expect(manager.restructureStore?.applied.first?.undoneAt == nil)
    }

    /// Accepting reaches the engine, and whatever it answers lands on the banner — here its refusal,
    /// since this manager has no profiles directory to re-point.
    @Test func acceptedReachesTheEngineAndReports() async throws {
        let (manager, dir) = try manager(holding: Self.record())
        defer { try? FileManager.default.removeItem(at: dir) }
        var asked = 0

        await ReorganisationUndo.run(manifestId: "m1", on: manager) { _, _ in
            asked += 1; return true
        }

        #expect(asked == 1)
        let banner = try #require(manager.banner, "the engine's answer reached no banner")
        #expect(banner.severity == .warning)
    }

    // MARK: Nothing goes around the question

    /// The engine call lives in one place. A surface that calls it directly runs an inverse that can
    /// move hundreds of files without asking — which is what both surfaces did.
    @Test func onlyTheSharedPathCallsTheEngine() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // FileExplorer package
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // repo root
        var callers: [String] = []
        for dir in ["MacApp", "Modules/FileExplorer/Sources", "Modules/Dashboard/Sources"] {
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                // The bare name: a call split across lines (`manager\n    .undoReorganisation(`)
                // or written without the label still matches.
                if text.contains("undoReorganisation(") {
                    callers.append(file.lastPathComponent)
                }
            }
        }
        #expect(callers == ["ReorganisationUndo.swift"],
                "the engine is called from \(callers) — a surface around the question")
    }
}
