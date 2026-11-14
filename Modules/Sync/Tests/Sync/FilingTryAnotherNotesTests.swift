import Foundation
import Testing
@testable import Sync

/// What Try Another says on a card, and the one click that sends a page to Claude: a folder that
/// asks each time stays on this Mac and offers the page; the click sends it; a failure or a reached
/// limit is the card's own note; and each request that reached Claude is reported.
extension HandBuiltRefineSuites {
@MainActor
@Suite struct FilingTryAnotherNotesTests {

    /// One manager for the suite, reset per test (see `HandBuiltFiling.reset`).
    private static var shared: FileSyncManager { HandBuiltFiling.manager }
    private static var defaults: ScratchDefaults { HandBuiltFiling.defaults }

    private func manager(_ claude: LockedBox<Int>, ending: @escaping @Sendable () -> FilingRefineResult.Ending = { .answered },
                         limit: Double? = nil) -> FileSyncManager {
        let m = Self.shared
        HandBuiltFiling.reset(m, defaults: Self.defaults)
        let defaults = Self.defaults
        if let limit { defaults.set(limit, forKey: AskClaudeSpend.limitDefaultsKey) }
        m.filingContentDefaults = defaults
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5-5" : FileSyncManager.onDeviceBackendIdentity }
        // This Mac's answer: Documents/Family, and Archive/2026 once Documents/Family was rejected.
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: $0.excludedRelativePaths.contains("Documents/Family") ? "Archive/2026" : "Documents/Family",
                                            confidence: .high, reason: "free"))
            })
        }
        m.filingRefineClassifier = { _, files in
            claude.withLock { $0 += 1 }
            let ending = ending()
            guard case .answered = ending else { return FilingRefineResult(ending: ending, started: true, costUSD: 0.002) }
            return FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Projects/Taxes", confidence: .high, reason: "claude"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.003)
        }
        return m
    }

    /// A scan that read each file's first page, as a real one does for a file on this Mac.
    private func scanned(_ m: FileSyncManager, files: Int = 1, readPages: Bool = true) async throws -> URL {
        let root = HandBuiltFiling.root("notes", files: files)
        HandBuiltFiling.build(m, root: root)
        if readPages { for s in m.filingSuggestions { m.filingPageSamples[s.filePath] = "Invoice from Northwind for March" } }
        return root
    }

    private func card(_ m: FileSyncManager) throws -> FilingSuggestion { try #require(m.filingSuggestions.first) }

    @Test func aFolderThatAsksEachTimeStaysOnThisMacAndOffersThePage() async throws {
        let claude = LockedBox(0)
        let m = manager(claude)
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        let c = try card(m)
        #expect(m.canAskClaudeWithPage(c))

        await m.tryAnotherFolder(for: c)

        #expect(claude.withLock { $0 } == 0)
        let note = try #require(m.filingTryAnotherNotes[c.filePath])
        #expect(note.text == "This folder asks before Claude reads files, so Try Another used this Mac." && note.offersClaudeWithPage)
    }

    /// A file whose first page wasn't read (cloud-only, or reading off): the click would send, and
    /// bill, its name alone, so neither the button nor the note offers it.
    @Test func noPageReadOffersNoPage() async throws {
        let claude = LockedBox(0)
        let m = manager(claude)
        let root = try await scanned(m, readPages: false); defer { try? FileManager.default.removeItem(at: root) }
        let c = try card(m)
        #expect(!m.canAskClaudeWithPage(c))

        await m.tryAnotherFolder(for: c)

        #expect(claude.withLock { $0 } == 0)
        #expect(m.filingTryAnotherNotes[c.filePath]?.offersClaudeWithPage == false)
    }

    @Test func theClickSendsThePageToClaudeAndClearsTheNote() async throws {
        let claude = LockedBox(0)
        let m = manager(claude)
        let reports = LockedBox<[FilingTryAnotherReport]>([])
        m.filingTryAnotherReports = { r in reports.withLock { $0.append(r) } }
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        let c = try card(m)
        await m.tryAnotherFolder(for: c)
        #expect(m.filingTryAnotherNotes[c.filePath] != nil)

        await m.tryAnotherFolder(for: try card(m), askingClaudeWithPage: true)

        #expect(claude.withLock { $0 } == 1, "the click is the request")
        #expect(m.filingTryAnotherNotes[c.filePath] == nil, "the note is gone: Claude answered")
        #expect(try card(m).best?.path.hasSuffix("Projects/Taxes") == true)
        #expect(reports.withLock { $0 } == [FilingTryAnotherReport(fileName: c.fileName, filePath: c.filePath, outcome: .answered, costUSD: 0.003, modelName: m.filingRefineModelName)])
    }

    /// The click asks Claude about what this Mac showed; it rejects nothing, so no folder he never
    /// turned down goes as "avoid" or is remembered against other files.
    @Test func theClickRejectsNothingThisMacShowed() async throws {
        let claude = LockedBox(0)
        let m = manager(claude)
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        await m.tryAnotherFolder(for: try card(m))
        let shown = try #require(try card(m).best?.path)
        #expect(shown.hasSuffix("Archive/2026"))
        let rejectionsBefore = m.filingRejections

        await m.tryAnotherFolder(for: try card(m), askingClaudeWithPage: true)

        #expect(claude.withLock { $0 } == 1)
        #expect(m.filingSessionRejections[try card(m).filePath]?.contains(shown) != true)
        #expect(m.filingRejections == rejectionsBefore)
    }

    /// This Mac found no other folder, so the card has none: the click still asks Claude.
    @Test func theClickAsksClaudeWhenThisMacFoundNothing() async throws {
        let claude = LockedBox(0)
        let m = manager(claude)
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        m.filingClassifier = { _, _, _ in [:] }
        await m.tryAnotherFolder(for: try card(m))
        #expect(try card(m).best == nil)
        #expect(m.filingTryAnotherNotes[try card(m).filePath]?.offersClaudeWithPage == true)

        await m.tryAnotherFolder(for: try card(m), askingClaudeWithPage: true)

        #expect(claude.withLock { $0 } == 1, "the click is the request")
        #expect(try card(m).best?.path.hasSuffix("Projects/Taxes") == true)
    }

    @Test func aSharedFolderAsksClaudeOnTheOrdinaryClickAndOffersNothing() async throws {
        let claude = LockedBox(0)
        let m = manager(claude)
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)
        let c = try card(m)
        #expect(!m.canAskClaudeWithPage(c), "its Try Another already asks Claude")
        await m.tryAnotherFolder(for: c)
        #expect(claude.withLock { $0 } == 1 && m.filingTryAnotherNotes[c.filePath] == nil)
    }

    @Test func aHiddenFileOffersNoClaudeAtAll() async throws {
        let m = manager(LockedBox(0))
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        let c = try card(m)
        AskClaudePrivacy.setHiddenFolders([root.appendingPathComponent("Downloads").path], in: m.filingContentDefaults)
        #expect(!m.canAskClaudeWithPage(c))
    }

    @Test func aFailureIsTheCardsOwnNoteAndIsReported() async throws {
        let claude = LockedBox(0)
        let m = manager(claude, ending: { .failed("The connection dropped.") })
        let reports = LockedBox<[FilingTryAnotherReport]>([])
        m.filingTryAnotherReports = { r in reports.withLock { $0.append(r) } }
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        let before = try card(m).best?.path
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)

        await m.tryAnotherFolder(for: try card(m))

        let note = try #require(m.filingTryAnotherNotes[try card(m).filePath])
        #expect(note.text == "Claude didn’t answer: The connection dropped. This card keeps its earlier suggestion. Nothing was saved as Claude’s." && !note.offersClaudeWithPage)
        #expect(try card(m).best?.path == before)
        #expect(reports.withLock { $0 }.map(\.outcome) == [.failed] && reports.withLock { $0 }.first?.costUSD == 0.002)
    }

    @Test func aReachedLimitIsTheCardsNoteAndNothingIsSent() async throws {
        let claude = LockedBox(0)
        let m = manager(claude, limit: 0.000001)
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)
        let c = try card(m)
        await m.tryAnotherFolder(for: c)
        #expect(claude.withLock { $0 } == 0)
        #expect(m.filingTryAnotherNotes[c.filePath]?.text.hasPrefix("Claude wasn’t asked: it would pass your monthly limit") == true)
    }

    @Test func anotherTryClearsTheNoteAndARescanClearsThemAll() async throws {
        let m = manager(LockedBox(0))
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        let c = try card(m)
        m.filingTryAnotherNotes[c.filePath] = .init(text: "old")
        await m.tryAnotherFolder(for: c)
        #expect(m.filingTryAnotherNotes[c.filePath]?.text != "old")

        m.filingTryAnotherNotes["/elsewhere.pdf"] = .init(text: "x")
        HandBuiltFiling.build(m, root: root)   // a rescan: the list is replaced
        #expect(m.filingTryAnotherNotes.isEmpty)
    }

    /// Customize… on a plan card is one rule for the session: Try Another's request to Claude leaves the
    /// same folders out, and a request that stays on this Mac is not changed by it.
    @Test func foldersLeftOutOnAPlanCardStayOutOfTryAnotherToo() async throws {
        let contexts = LockedBox<[[String]]>([])
        let claude = LockedBox(0)
        let m = manager(claude)
        m.filingRefineClassifier = { context, files in
            claude.withLock { $0 += 1 }; contexts.withLock { $0.append(context.destinations) }
            return FilingRefineResult(ending: .answered, verdicts: Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Projects/Taxes", confidence: .high, reason: "claude"))
            }), answered: files.count, sent: files.count, started: true, costUSD: 0.001)
        }
        let root = try await scanned(m); defer { try? FileManager.default.removeItem(at: root) }
        AskClaudePrivacy.shareWithoutAsking(root.appendingPathComponent("Downloads").path, in: m.filingContentDefaults)
        m.filingRefineLeftOutFolders = ["Archive"]

        await m.tryAnotherFolder(for: try card(m))

        let sent = try #require(contexts.withLock { $0 }.first)
        #expect(!sent.contains { $0 == "Archive" || $0.hasPrefix("Archive/") }, "left out: \(sent)")
        #expect(sent.contains { $0.hasPrefix("Documents") })
    }

    @Test func theRunningLineCountsFilesRequestsFailuresAndCost() {
        var line = AskClaudeTryAnotherLine()
        line.add(.init(fileName: "a.pdf", outcome: .answered, costUSD: 0.01, modelName: "Opus 5.5"))
        line.add(.init(fileName: "a.pdf", outcome: .failed, costUSD: 0.01, modelName: "Opus 5.5"))
        line.add(.init(fileName: "b.pdf", outcome: .answered, costUSD: 0.01, modelName: "Opus 5.5"))
        #expect(line.text == "Try Another · 2 files · 3 requests, 1 failed · 3¢ this hour · Opus 5.5")
        var one = AskClaudeTryAnotherLine()
        one.add(.init(fileName: "a.pdf", outcome: .answered, costUSD: 0, modelName: ""))
        #expect(one.text == "Try Another · 1 file · 1 request · no cost recorded this hour")
        let back = try? JSONDecoder().decode(AskClaudeTryAnotherLine.self, from: JSONEncoder().encode(line))
        #expect(back == line)
        #expect((try? JSONDecoder().decode(AskClaudeTryAnotherLine.self, from: Data("{}".utf8))) == AskClaudeTryAnotherLine())
    }
}
}
