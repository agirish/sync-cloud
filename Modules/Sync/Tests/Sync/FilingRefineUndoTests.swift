import Foundation
import Testing
@testable import Sync

/// Undo Refine: the on-device suggestions come back for the files a pass moved, except where the
/// person has chosen since; a rescan makes the list another one and Undo goes with it.
extension HandBuiltRefineSuites {
@MainActor
@Suite struct FilingRefineUndoTests {

    /// One manager for the suite, reset per test (see `HandBuiltFiling.reset`).
    private static var shared: FileSyncManager { HandBuiltFiling.manager }
    private static var defaults: ScratchDefaults { HandBuiltFiling.defaults }

    private func manager() -> FileSyncManager {
        let m = Self.shared
        HandBuiltFiling.reset(m, defaults: Self.defaults)
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Documents/Family", confidence: .high, reason: "free"))
            })
        }
        m.filingRefineClassifier = { _, files in
            FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Archive/2026", confidence: .high, reason: "claude says so"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.001)
        }
        return m
    }

    private func refined(files: Int = 3, _ m: FileSyncManager) async throws -> (URL, [String: String]) {
        let root = HandBuiltFiling.root("undo", files: files)
        HandBuiltFiling.build(m, root: root)
        let before = Dictionary(uniqueKeysWithValues: m.filingSuggestions.map { ($0.fileName, $0.best?.path ?? "") })
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions))
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        return (root, before)
    }

    private func homes(_ m: FileSyncManager) -> [String: String] {
        Dictionary(uniqueKeysWithValues: m.filingSuggestions.map { ($0.fileName, $0.best?.path ?? "") })
    }

    @Test func undoPutsTheOnDeviceSuggestionsBackAndTheReportNamesThePassesAnswers() async throws {
        let m = manager()
        let (root, before) = try await refined(m); defer { try? FileManager.default.removeItem(at: root) }
        #expect(homes(m) != before && m.canUndoFilingRefine)
        let report = try #require(m.filingLastRefineReport)
        #expect(report.changes.count == 3 && report.changes.allSatisfy { $0.reason == "claude says so" && $0.after == "Archive/2026" })

        #expect(m.undoFilingRefine() == 3)
        #expect(homes(m) == before, "every file is back where the free pass put it")
        #expect(!m.canUndoFilingRefine && m.filingLastRefine == nil, "nothing left to undo, and no refined pill")
        #expect(m.undoFilingRefine() == 0, "a second Undo does nothing")
    }

    @Test func aHomeTheyChoseSinceStaysTheirs() async throws {
        let m = manager()
        let (root, before) = try await refined(m); defer { try? FileManager.default.removeItem(at: root) }
        // One file's card is changed by hand after the pass (Try Another, or a folder picked).
        let card = try #require(m.filingSuggestions.first { $0.fileName == "mystery-1.pdf" })
        let mine = FilingDestination(path: root.appendingPathComponent("Documents").path, base: .high, evidence: .name, reasons: ["mine"], newSegments: [])
        m.replaceFilingSuggestion(card.id, candidates: [mine])

        #expect(m.undoFilingRefine() == 2)
        let after = homes(m)
        #expect(after["mystery-1.pdf"] == root.appendingPathComponent("Documents").path, "the one they chose is left alone")
        #expect(after["mystery-0.pdf"] == before["mystery-0.pdf"] && after["mystery-2.pdf"] == before["mystery-2.pdf"])
    }

    @Test func aRescanTakesUndoAwayBecauseItIsAnotherList() async throws {
        let m = manager()
        let (root, _) = try await refined(m); defer { try? FileManager.default.removeItem(at: root) }
        #expect(m.canUndoFilingRefine)
        HandBuiltFiling.build(m, root: root)   // a rescan: the list is replaced
        #expect(!m.canUndoFilingRefine)
        #expect(m.undoFilingRefine() == 0)
    }

    @Test func aPassThatChangedNothingHasNothingToUndo() async throws {
        let m = manager()
        m.filingRefineClassifier = { _, files in
            FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Documents/Family", confidence: .high, reason: "same"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.001)
        }
        let (root, _) = try await refined(m); defer { try? FileManager.default.removeItem(at: root) }
        #expect(m.filingRefineUndo == nil && !m.canUndoFilingRefine)
        #expect(m.filingLastRefineReport?.changes.isEmpty == true)
    }

    @Test func aNewPassReplacesWhatUndoWouldPutBack() async throws {
        let m = manager()
        let (root, _) = try await refined(m); defer { try? FileManager.default.removeItem(at: root) }
        _ = try #require(m.filingRefineUndo)
        let plan = try #require(await m.prepareFilingRefine(m.filingSuggestions, options: .init(askAgain: true)))
        _ = await m.sendFilingRefine(plan, scope: m.filingSuggestions)
        // Asked again, Claude gave the same homes: nothing moved, so there is nothing to undo, rather
        // than an Undo that would reach back past this pass.
        #expect(m.filingRefineUndo == nil)
    }

    @Test func theBannerIsTheCardsJobWhereThereIsAChat() async throws {
        let m = manager()
        m.filingRefineShowsBanner = false
        let (root, _) = try await refined(m); defer { try? FileManager.default.removeItem(at: root) }
        #expect(m.banner == nil, "the card in the chat says it")
        #expect(m.filingLastRefineReport != nil)

        let shown = manager()
        let (root2, _) = try await refined(shown); defer { try? FileManager.default.removeItem(at: root2) }
        #expect(shown.banner?.message.hasPrefix("Refined 3 suggestions") == true, "without a chat the banner stays")
    }
}
}
