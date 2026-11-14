import Foundation
import Testing
@testable import Sync

/// Refine honours Hidden from Claude (Settings ▸ Ask Claude ▸ Privacy), as Ask Claude does: a
/// hidden file's name and page never go, and a hidden folder is never sent as a destination or an
/// "avoid", nor taken as an answer.
///
/// Each test pairs the hidden run with an unhidden control, so a filter that does nothing fails.
@MainActor
@Suite struct FilingRefineHiddenFromClaudeTests {

    /// Everything a `.refine` call carried.
    private typealias Sent = LockedBox<[(destinations: [String], files: [FilingCandidateFile])]>

    private func fixture(_ name: String) throws -> URL { try refineFixture(prefix: "RefineHidden-\(name)") }

    /// The scan answers Documents/Family, Refine answers Archive/2026, so a refined home is visible.
    /// `hidden` is the Hidden from Claude list, as absolute paths.
    private func manager(_ sent: Sent, hidden: [String],
                         refineAnswer: String = "Archive/2026") -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingRefineHiddenFromClaudeTests")
        AskClaudePrivacy.setHiddenFolders(hidden, in: m.filingContentDefaults)
        m.filingBackendIdentity = { tier in
            tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity
        }
        m.filingCloudSpendConfirmer = { _ in true }
        m.filingClassifier = { context, files, tier in
            if tier == .refine { sent.record(context, files) }
            let dest = tier == .refine ? refineAnswer : "Documents/Family"
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
        #expect(m.banner?.isRefusal == true, "nothing was sent, so Activity keeps it for this session only")
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
        // A refusal, so the hidden file's name is never written to the kept messages file.
        #expect(m.banner?.isRefusal == true)

        // The unhidden file in the same scan is re-asked, so the loop above could reach a re-ask.
        await tryAnotherUntilReAsked(m, sent, file: "mystery-1.pdf")
        #expect(sent.all.map { $0.files.map(\.fileName) } == [["mystery-1.pdf"]])
    }

    /// The folder list, the "avoid" list and the answer, for Try Another, against a control.
    @Test func tryAnotherLeavesHiddenFoldersOutAndTakesNoAnswerInOne() async throws {
        func run(hiding: Bool) async throws -> (destinations: [String], avoid: [String], best: String?) {
            let root = try fixture(hiding ? "tryanother-folder" : "tryanother-folder-control")
            defer { try? FileManager.default.removeItem(at: root) }
            let sent = Sent()
            let m = manager(sent, hidden: hiding ? [path(root, "Archive")] : [])
            await scan(m, root: root)
            // A folder rejected for this file earlier, inside the hidden one.
            m.filingSessionRejections[path(root, "Downloads/mystery-0.pdf")] = [path(root, "Archive/Old")]
            await tryAnotherUntilReAsked(m, sent, file: "mystery-0.pdf")
            let call = try #require(sent.all.first)
            return (call.destinations, call.files.first?.excludedRelativePaths ?? [],
                    m.filingSuggestions.first { $0.fileName == "mystery-0.pdf" }?.best?.path)
        }

        let shown = try await run(hiding: false)
        #expect(shown.destinations.contains("Archive/2026"), "the control never offered the folder")
        #expect(shown.avoid.contains("Archive/Old"))
        #expect(shown.best?.hasSuffix("Archive/2026") == true)

        let hidden = try await run(hiding: true)
        #expect(!hidden.destinations.contains { $0 == "Archive" || $0.hasPrefix("Archive/") })
        #expect(!hidden.destinations.isEmpty)
        #expect(!hidden.avoid.contains { $0.hasPrefix("Archive") })
        #expect(hidden.avoid.contains("Documents/Family"), "the folder just rejected still goes as avoid")
        // Claude answered Archive/2026; it is not put on the card.
        #expect(hidden.best?.hasSuffix("Archive/2026") != true)
    }

    // MARK: An answer spelled another way

    /// `applyVerdicts` trims an answer and strips an echoed root, so the check must read the folder
    /// it resolves to: " <root>/Archive/2026 " lands in Archive/2026.
    @Test func anAnswerSpelledWithTheRootStillCannotLandInAHiddenFolder() async throws {
        func home(hiding: Bool) async throws -> String? {
            let root = try fixture(hiding ? "spelled" : "spelled-control")
            defer { try? FileManager.default.removeItem(at: root) }
            let sent = Sent()
            let m = manager(sent, hidden: hiding ? [path(root, "Archive")] : [],
                            refineAnswer: " \(root.path)/Archive/2026 ")
            await scan(m, root: root)
            _ = try #require(await m.refineFilingSuggestions(m.filingSuggestions))
            return m.filingSuggestions.first { $0.fileName == "mystery-1.pdf" }?.best?.path
        }
        // The control shows the spelling is accepted and lands in Archive/2026…
        #expect(try await home(hiding: false)?.hasSuffix("Archive/2026") == true)
        // …so hidden, it is the check, not the spelling, that keeps the free home.
        #expect(try await home(hiding: true)?.hasSuffix("Documents/Family") == true)
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
        let request = MappingRefineRequest(family: "Docs/Immigration", members: ["2016", "2019"],
                                           rows: [.init(source: "Petition", target: nil)],
                                           candidateVocabularies: [["application"]])
        for (hidden, refused) in [
            ("/r/Docs/Immigration", true),                  // the family
            ("/r/Docs/Immigration/2019", true),             // a member
            ("/r/Docs/Immigration/2016/Petition", true),    // a mapped folder
            ("/r/Docs/Taxes", false),                       // elsewhere
        ] {
            let refined = LockedBox(0)
            let m = mappingManager(hidden: [hidden])
            m.mappingRefiner = { _ in
                refined.withLock { $0 += 1 }
                return []
            }
            let outcome = await m.refineMapping(request, under: "/r")
            #expect((outcome == .hiddenFromClaude) == refused, "hiding \(hidden)")
            #expect((refined.withLock { $0 } == 0) == refused, "hiding \(hidden)")
        }
    }

    /// With the group on, `rows` carries sibling families' child names; a hidden sibling stops it.
    @Test func aGroupMappingThatDrawsOnAHiddenSiblingIsRefused() async {
        func outcome(hiding hidden: String, drawnFrom: [String]?) async -> (FileSyncManager.MappingRefineOutcome, Int) {
            let refined = LockedBox(0)
            let m = mappingManager(hidden: [hidden])
            m.mappingRefiner = { _ in refined.withLock { $0 += 1 }; return [] }
            // "Divorce Settlement" exists only under the sibling family Taxes/Spouse.
            let request = MappingRefineRequest(family: "Taxes/Me", members: ["2023", "2024"],
                                               rows: [.init(source: "Receipts", target: nil),
                                                      .init(source: "Divorce Settlement", target: nil)],
                                               candidateVocabularies: [["receipts"]],
                                               drawnFrom: drawnFrom)
            return (await m.refineMapping(request, under: "/r"), refined.withLock { $0 })
        }
        let group = ["Taxes/Me/2023", "Taxes/Me/2024", "Taxes/Spouse/2024"]
        // The sibling's member, and a folder inside it, are each refused.
        for hidden in ["/r/Taxes/Spouse", "/r/Taxes/Spouse/2024/Divorce Settlement"] {
            let (result, refined) = await outcome(hiding: hidden, drawnFrom: group)
            #expect(result == .hiddenFromClaude, "hiding \(hidden)")
            #expect(refined == 0, "hiding \(hidden)")
        }
        // Control: without the sibling in drawnFrom (this family alone), the same hidden folder is
        // not seen — which is why the sheet must pass the group's folders.
        let (alone, aloneRefined) = await outcome(hiding: "/r/Taxes/Spouse/2024/Divorce Settlement", drawnFrom: nil)
        #expect(alone != .hiddenFromClaude)
        #expect(aloneRefined == 1)
    }
}

private extension LockedBox where Value == [(destinations: [String], files: [FilingCandidateFile])] {
    convenience init() { self.init([]) }
    func record(_ context: FilingContext, _ files: [FilingCandidateFile]) { withLock { $0.append((context.destinations, files)) } }
    var all: [(destinations: [String], files: [FilingCandidateFile])] { withLock { $0 } }
}
