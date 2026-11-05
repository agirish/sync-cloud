import Foundation
import Testing
@testable import Sync

/// **Refine honours Hidden from Claude** (Settings ▸ Intelligence). The list said "Claude is never
/// shown these folders and files … not their names", but only Ask Claude read it: Refine sent a
/// hidden file's name and page, and every hidden folder as a destination or an "avoid".
///
/// Each test pairs the hidden run with an unhidden control, so a filter that does nothing fails.
@MainActor
@Suite struct FilingRefineHiddenFromClaudeTests {

    /// Everything a `.refine` call carried.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(destinations: [String], files: [FilingCandidateFile])] = []
        func record(_ context: FilingContext, _ files: [FilingCandidateFile]) {
            lock.lock(); defer { lock.unlock() }; calls.append((context.destinations, files))
        }
        var all: [(destinations: [String], files: [FilingCandidateFile])] {
            lock.lock(); defer { lock.unlock() }; return calls
        }
    }

    private func write(_ url: URL, bytes: Int = 5000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func fixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "RefineHidden-\(name)")
        try write(root.appendingPathComponent("Documents/Family/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Archive/2026/.keep"), bytes: 1)
        for i in 0..<2 { try write(root.appendingPathComponent("Downloads/mystery-\(i).pdf")) }
        return root
    }

    /// The scan answers Documents/Family, Refine answers Archive/2026, so a refined home is visible.
    /// `hidden` is the Hidden from Claude list, as absolute paths.
    private func manager(_ sent: Sent, hidden: [String]) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingRefineHiddenFromClaudeTests")
        AskClaudePrivacy.setHiddenFolders(hidden, in: m.filingContentDefaults)
        m.filingBackendIdentity = { tier in
            tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity
        }
        m.filingCloudSpendConfirmer = { _ in true }
        m.filingClassifier = { context, files, tier in
            if tier == .refine { sent.record(context, files) }
            let dest = tier == .refine ? "Archive/2026" : "Documents/Family"
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: dest, confidence: .high, reason: "test"))
            })
        }
        return m
    }

    private func scan(_ m: FileSyncManager, root: URL) async {
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
    }

    private func path(_ root: URL, _ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    // MARK: A hidden file

    @Test func aHiddenFileIsNeitherCountedNorSentAndTheBannerSaysSo() async throws {
        let root = try fixture("file")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent, hidden: [path(root, "Downloads/mystery-0.pdf")])
        await scan(m, root: root)
        #expect(m.filingSuggestions.count == 2)

        // The button's count is what is sent.
        let eligible = m.filingSuggestionsEligibleForRefine(m.filingSuggestions)
        #expect(eligible.map(\.fileName) == ["mystery-1.pdf"])
        #expect(m.filingSuggestionsHiddenFromClaude(m.filingSuggestions) == 1)

        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(sent.all.flatMap { $0.files.map(\.fileName) } == ["mystery-1.pdf"])
        #expect(summary.asked == 1)
        #expect(summary.hiddenFromClaude == 1)
        #expect(m.banner?.message.hasSuffix("1 file hidden from Claude was left out.") == true)
        // The hidden file keeps the free home; the other took Refine's.
        let homes = Dictionary(uniqueKeysWithValues: m.filingSuggestions.map { ($0.fileName, $0.best?.path) })
        #expect(homes["mystery-0.pdf"] == path(root, "Documents/Family"))
        #expect(homes["mystery-1.pdf"] == path(root, "Archive/2026"))
    }

    @Test func everyFileHiddenSendsNothingAndSaysWhy() async throws {
        let root = try fixture("allfiles")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent, hidden: [path(root, "Downloads")])
        await scan(m, root: root)
        #expect(m.filingSuggestions.count == 2)

        #expect(await m.refineFilingSuggestions(m.filingSuggestions) == nil)
        #expect(sent.all.isEmpty)
        #expect(m.banner?.message == "Nothing was sent — those files are hidden from Claude.")
    }

    @Test func withNothingHiddenEveryFileIsSent() async throws {
        let root = try fixture("control")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent, hidden: [])
        await scan(m, root: root)
        let summary = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        #expect(sent.all.flatMap { $0.files.map(\.fileName) }.sorted() == ["mystery-0.pdf", "mystery-1.pdf"])
        #expect(summary.hiddenFromClaude == 0)
        #expect(m.banner?.message.contains("hidden from Claude") == false)
    }

    // MARK: A hidden folder

    /// The folder list, the "avoid" list and the answer: a hidden folder is in none of them.
    @Test func aHiddenFolderIsNotOfferedNotAvoidedAndNotTaken() async throws {
        func run(hiding: Bool) async throws -> (destinations: [String], avoid: [String], homes: Set<String?>) {
            let root = try fixture(hiding ? "folder" : "folder-control")
            defer { try? FileManager.default.removeItem(at: root) }
            let sent = Sent()
            let m = manager(sent, hidden: hiding ? [path(root, "Archive")] : [])
            await scan(m, root: root)
            // A folder rejected for mystery-0 goes out as "avoid".
            m.filingSessionRejections[path(root, "Downloads/mystery-0.pdf")] = [path(root, "Archive/2026")]
            _ = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
            let call = try #require(sent.all.first)
            return (call.destinations,
                    call.files.first { $0.fileName == "mystery-0.pdf" }?.excludedRelativePaths ?? [],
                    Set(m.filingSuggestions.filter { $0.fileName == "mystery-1.pdf" }.map { $0.best?.path }))
        }

        let shown = try await run(hiding: false)
        #expect(shown.destinations.contains("Archive/2026"), "the control never offered the folder")
        #expect(shown.avoid == ["Archive/2026"])
        #expect(shown.homes.allSatisfy { $0?.hasSuffix("Archive/2026") == true })

        let hidden = try await run(hiding: true)
        #expect(!hidden.destinations.contains { $0 == "Archive" || $0.hasPrefix("Archive/") })
        #expect(hidden.destinations.contains("Documents/Family"))
        #expect(hidden.avoid.isEmpty)
        // Claude answered Archive/2026 anyway; it is not taken, and the free home stands.
        #expect(hidden.homes.allSatisfy { $0?.hasSuffix("Documents/Family") == true })
    }

    /// The card's own home is offered first (`preferred`); hidden, it is not offered at all.
    @Test func aHiddenFolderTheScanChoseIsNotOfferedEither() async throws {
        let root = try fixture("preferred")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent, hidden: [path(root, "Documents")])
        await scan(m, root: root)
        // The free pass still chose the hidden folder: it runs on this Mac.
        #expect(m.filingSuggestions.allSatisfy { $0.best?.path == path(root, "Documents/Family") })
        _ = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
        let call = try #require(sent.all.first)
        #expect(!call.destinations.contains { $0 == "Documents" || $0.hasPrefix("Documents/") })
        #expect(call.destinations.contains("Archive/2026"))
    }

    // MARK: Try Another

    /// Clicks Try Another until the card runs out of local ideas and re-asks (or gives up).
    private func tryAnotherUntilReAsked(_ m: FileSyncManager, _ sent: Sent, file: String) async {
        for _ in 0..<6 where sent.all.isEmpty {
            guard let card = m.filingSuggestions.first(where: { $0.fileName == file }),
                  card.best != nil else { return }
            await m.tryAnotherFolder(for: card)
        }
    }

    @Test func tryAnotherOnAHiddenFileAsksNothing() async throws {
        let root = try fixture("tryanother")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent, hidden: [path(root, "Downloads/mystery-0.pdf")])
        await scan(m, root: root)
        await tryAnotherUntilReAsked(m, sent, file: "mystery-0.pdf")
        #expect(sent.all.isEmpty)
        #expect(m.banner?.message == "“mystery-0.pdf” is hidden from Claude, so it wasn’t asked for another folder. Choose one instead.")

        // The unhidden file in the same scan is re-asked, so the loop above could reach a re-ask.
        await tryAnotherUntilReAsked(m, sent, file: "mystery-1.pdf")
        #expect(sent.all.map { $0.files.map(\.fileName) } == [["mystery-1.pdf"]])
    }

    @Test func tryAnotherLeavesHiddenFoldersOutOfTheList() async throws {
        let root = try fixture("tryanother-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let sent = Sent()
        let m = manager(sent, hidden: [path(root, "Archive")])
        await scan(m, root: root)
        await tryAnotherUntilReAsked(m, sent, file: "mystery-0.pdf")
        let call = try #require(sent.all.first)
        #expect(!call.destinations.contains { $0.hasPrefix("Archive") })
        #expect(!call.destinations.isEmpty)
    }

    // MARK: The mapping refine

    private func mappingManager(hidden: [String]) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingBackendIdentity = { _ in "cloud:claude" }
        m.filingContentDefaults = ScratchDefaults("FilingRefineHiddenFromClaudeTests-mapping")
        AskClaudePrivacy.setHiddenFolders(hidden, in: m.filingContentDefaults)
        m.filingCloudSpendConfirmer = { _ in true }
        return m
    }

    @Test func aMappingThatNamesAHiddenFolderIsRefusedBeforeAnythingIsSent() async {
        final class Count: @unchecked Sendable { var refined = 0 }
        let request = MappingRefineRequest(family: "Docs/Immigration", members: ["2016", "2019"],
                                           rows: [.init(source: "Petition", target: nil)],
                                           candidateVocabularies: [["application"]])
        for (hidden, refused) in [
            ("/r/Docs/Immigration", true),                  // the family
            ("/r/Docs/Immigration/2019", true),             // a member
            ("/r/Docs/Immigration/2016/Petition", true),    // a mapped folder
            ("/r/Docs/Taxes", false),                       // elsewhere
        ] {
            let count = Count()
            let m = mappingManager(hidden: [hidden])
            m.mappingRefiner = { _ in
                count.refined += 1
                return []
            }
            let outcome = await m.refineMapping(request, under: "/r")
            #expect((outcome == .hiddenFromClaude) == refused, "hiding \(hidden)")
            #expect((count.refined == 0) == refused, "hiding \(hidden)")
        }
    }
}
