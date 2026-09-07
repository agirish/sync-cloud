import Foundation
import Testing
@testable import Sync

/// **The cross-person rule guarded one input, and the cards were not it.**
///
/// `applyVerdicts` consulted it before promoting a backend verdict, and "Try another" before
/// accepting one. Both are the model's answers — and when the rule fires in either place it
/// declines the model and restores the home the keyword engine or the router had already put on the
/// card, which nothing had ever tested. The router's own protection is a −3.0 score penalty: a
/// preference, not a refusal.
///
/// So on a machine with no Apple Intelligence the rule was reachable on no card at all: the
/// classifier returns `[:]`, every `applyVerdicts` short-circuits on the empty dictionary, and every
/// card shows a router or keyword home. That is the default install.
///
/// These pin the sweep itself and — the half that matters, because a rule extracted for testability
/// is one revert from being unused — the two call sites that produce homes without a verdict.
@Suite struct FilingCrossPersonSweepTests {

    static let root = "/root"

    static let household = PersonRegistry(people: [
        Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        Person(id: "son", displayName: "Son", fullNames: ["Son Father"]),
    ])

    static func profile() -> FolderProfile {
        let entries = [
            FolderProfileEntry(path: "Immigration/OCI/Son", role: .destination, naming: nil,
                               anchors: [], acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0,
                               axes: ["person": "Son"]),
            FolderProfileEntry(path: "Immigration/OCI/Daughter", role: .destination, naming: nil,
                               anchors: [], acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0,
                               axes: ["person": "Daughter"]),
            FolderProfileEntry(path: "Immigration/OCI", role: .container, naming: nil,
                               anchors: [], acceptsNewFiles: nil, fileCount: 0, subfolderCount: 2,
                               axes: [:]),
        ]
        return FolderProfile(profileId: "t", root: "~",
                             folders: Dictionary(entries.map { ($0.path, $0) },
                                                 uniquingKeysWith: { a, _ in a }),
                             personTokens: ["daughter", "son"])
    }

    static func dest(_ relative: String, remembered: Bool = false,
                     confidence: FilingConfidence = .high) -> FilingDestination {
        FilingDestination(path: "\(root)/\(relative)", confidence: confidence, reasons: ["r"],
                          newSegments: [], remembered: remembered)
    }

    static func card(_ name: String, _ candidates: [FilingDestination]) -> FilingSuggestion {
        FilingSuggestion(filePath: "\(root)/Downloads/\(name)", fileName: name, size: 1000,
                         modificationDate: nil, candidates: candidates, providerRoot: root)
    }

    static func sweep(_ cards: [FilingSuggestion],
                      pageSamples: [String: String] = [:],
                      onVeto: ((PersonVetoRefusal) -> Void)? = nil) -> [FilingSuggestion] {
        FilingEngine.refusingCrossPersonHomes(cards, providerRoot: root, profile: profile(),
                                              registry: household, identity: nil,
                                              pageSamples: pageSamples, onVeto: onVeto)
    }

    // MARK: The sweep

    /// The whole point: a home nobody asked a model about is refused, and the next candidate leads.
    @Test func aWrongPersonHomeIsDroppedAndTheNextCandidateLeads() throws {
        let out = Self.sweep([Self.card("Daughter OCI.pdf", [
            Self.dest("Immigration/OCI/Son"),
            Self.dest("Immigration/OCI/Daughter"),
        ])])
        let card = try #require(out.first)
        #expect(card.candidates.count == 1)
        #expect(card.best?.path == "\(Self.root)/Immigration/OCI/Daughter")
    }

    /// **Removal, not demotion.** A card whose only home is someone else's folder is the case the
    /// rule most exists for, and demoting a sole candidate leaves it leading. No home is the
    /// answer: the queue already renders that state, and the user can still file it by hand.
    @Test func aCardWhoseOnlyHomeIsAnothersFolderIsLeftWithNone() throws {
        let out = Self.sweep([Self.card("Daughter OCI.pdf", [Self.dest("Immigration/OCI/Son")])])
        let card = try #require(out.first)
        #expect(card.candidates.isEmpty)
        #expect(card.best == nil)
    }

    /// **A home the user taught is an instruction, not a guess** — the same exemption
    /// `applyVerdicts` opens with. `remembered` covers both a learned rule and an automation the
    /// user wrote, and an automation resolving `{person}` through this very registry would
    /// otherwise be refused by it.
    @Test func aRememberedHomeIsExempt() throws {
        let out = Self.sweep([Self.card("Daughter OCI.pdf", [
            Self.dest("Immigration/OCI/Son", remembered: true),
        ])])
        let card = try #require(out.first)
        #expect(card.best?.path == "\(Self.root)/Immigration/OCI/Son")
    }

    /// Reported once per card, for the highest-ranked refusal: the card had one home the user would
    /// have seen, and a file whose every candidate is someone else's folder is one event, not two.
    @Test func aCardReportsOneRefusalHoweverManyOfItsHomesAreRefused() throws {
        final class Box: @unchecked Sendable { var reports: [PersonVetoRefusal] = [] }
        let box = Box()
        _ = Self.sweep([Self.card("Daughter OCI.pdf", [
            Self.dest("Immigration/OCI/Son"),
            Self.dest("Immigration/OCI/Son/Application"),
        ])], onVeto: { box.reports.append($0) })
        #expect(box.reports.count == 1)
        // The one the user would have been shown, not whichever was refused last.
        #expect(box.reports.first?.destination == "Immigration/OCI/Son")
    }

    /// The other direction, so the sweep is not simply emptying every card: a correct home, and a
    /// folder with no person axis at all, both survive untouched — and an untouched card is
    /// returned as-is rather than rebuilt.
    @Test func correctAndUnownedHomesSurvive() throws {
        let cards = [Self.card("Daughter OCI.pdf", [
            Self.dest("Immigration/OCI/Daughter"),
            Self.dest("Immigration/Passports"),
        ])]
        let out = Self.sweep(cards)
        #expect(out == cards)
    }

    /// No profile ⇒ no folder has a person axis ⇒ nothing to contradict. Pinned because the early
    /// return also skips the per-candidate work on a tree that was never surveyed.
    @Test func withoutAProfileNothingIsRefused() throws {
        let cards = [Self.card("Daughter OCI.pdf", [Self.dest("Immigration/OCI/Son")])]
        let out = FilingEngine.refusingCrossPersonHomes(
            cards, providerRoot: Self.root, profile: nil, registry: Self.household)
        #expect(out == cards)
    }

    /// A file whose own name names nobody is judged on the page it was read from — the tier that
    /// gives `Scan 2026-08-02.pdf` an answer at all. Pinned here because the sweep is what passes
    /// the samples through, and passing an empty dictionary would silently disarm the tier.
    @Test func aNamelessFileIsJudgedOnItsPage() throws {
        let card = Self.card("Scan 2026-08-02.pdf", [Self.dest("Immigration/OCI/Son")])
        let out = Self.sweep([card], pageSamples: [card.filePath: "Daughter Father OCI application"])
        #expect(out.first?.candidates.isEmpty == true)
        // …and with no sample, nothing is known and nothing is refused.
        #expect(Self.sweep([card]) == [card])
    }
}

/// The two paths that put a home on a card without a backend verdict anywhere near it.
@Suite @MainActor struct FilingCrossPersonSweepCallSiteTests {

    static func write(_ url: URL, bytes: Int = 5000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// A tree with Son's OCI folder and a loose document named for Daughter. No classifier is
    /// injected, so `applyVerdicts` never runs — which is the ordinary state on a machine without
    /// Apple Intelligence, and was the state in which the rule could not fire at all.
    static func makeTree() throws -> (FileSyncManager, URL) {
        let root = try makeCanonicalTempRoot(prefix: "CrossPersonSweep")
        try write(root.appendingPathComponent("Documents/Immigration/OCI/Son/Son - eOCI.pdf"))
        try write(root.appendingPathComponent("Documents/Immigration/OCI/Son/OCI Application.pdf"))
        try write(root.appendingPathComponent("Downloads/Daughter OCI.pdf"))
        let m = FileSyncManager()
        let entries = [
            FolderProfileEntry(path: "Documents/Immigration/OCI/Son", role: .destination,
                               naming: nil, anchors: ["oci"], acceptsNewFiles: nil,
                               fileCount: 2, subfolderCount: 0, axes: ["person": "Son"]),
        ]
        m.filingFolderProfile = FolderProfile(
            profileId: "t", root: "~",
            folders: Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
            personTokens: ["daughter", "son"])
        m.filingPersonRegistry = PersonRegistry(people: [
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
            Person(id: "son", displayName: "Son", fullNames: ["Son Father"]),
        ])
        return (m, root)
    }

    /// **The scan.** Without the sweep the card leads with `…/OCI/Son` — the keyword engine put
    /// it there on the strength of "oci", and nothing downstream looks at whose folder it is.
    @Test func theScanRefusesAnotherPersonsFolder() async throws {
        let (m, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = PersonVetoLog(userDefaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!)
        m.filingPersonVetoLog = log

        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        let card = try #require(m.filingSuggestions.first { $0.fileName == "Daughter OCI.pdf" })
        // The premise, so this cannot pass by the engine simply never suggesting the folder.
        #expect(!card.candidates.isEmpty || log.events.count == 1,
                "nothing suggested Son's folder — the fixture stopped exercising the rule")
        #expect(!card.candidates.contains { $0.path.hasSuffix("/OCI/Son") },
                "the scan offered one person's document a home in another's folder")
        #expect(log.events.first?.proposedPerson == "son")
        #expect(log.events.first?.namedPerson == "daughter")
    }

    /// **One page sample, so the scan and a later re-ask agree about who a document is about.**
    ///
    /// The rule reads the page only for a file whose own NAME names nobody, and what it is handed
    /// differs by surface: the scan had the extractor's full return (up to 20,000 characters) while
    /// "Try another" and the OCR re-read get `filingPageSamples`, truncated to the 400 the scorer
    /// was measured on. A name printed past that cut therefore attributed the document during the
    /// scan and not on a re-ask — two answers to one question about one file.
    ///
    /// Here the name sits past the cut, so nothing may be refused. The card keeps its home.
    @Test func aNamePastTheSampleCutDoesNotDecideTheScan() async throws {
        let (m, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = PersonVetoLog(userDefaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!)
        m.filingPersonVetoLog = log
        // A nameless scan, whose page names Daughter only after 400 characters of filler.
        try Self.write(root.appendingPathComponent("Downloads/Scan 2026-08-02.pdf"))
        let filler = String(repeating: "oci application overseas citizen india ", count: 40)
        try #require(filler.count > FilingRouter.contentSampleChars)
        m.filingSnippetExtractor = { _ in filler + " Daughter Father" }
        m.filingTokensFromText = { _ in ["oci"] }
        m.filingContentExtractor = { _ in ["oci"] }

        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        let card = try #require(m.filingSuggestions.first { $0.fileName == "Scan 2026-08-02.pdf" })
        // The premise: the scan really did offer Son's folder for this file.
        // The sibling card, whose FILENAME names Daughter, is refused as it should be — the fixture
        // proves the rule is live in this scan rather than quietly absent.
        try #require(log.events.contains { $0.fileName == "Daughter OCI.pdf" },
                     "the rule did not fire at all here — the fixture stopped exercising it")
        #expect(!log.events.contains { $0.fileName == "Scan 2026-08-02.pdf" },
                "a name past the sample cut decided the scan, which a re-ask could not see")
        #expect(card.candidates.contains { $0.path.hasSuffix("/OCI/Son") })
    }

    /// **The OCR re-read.** `readScan` routes one card and writes the home straight onto it — no
    /// `applyVerdicts`, so before the sweep it was a second live way into someone else's folder.
    /// And the file it exists for is a scan with no text layer, which is the rule's own worked
    /// example: `Son - eOCI.pdf` extracts nothing.
    @Test func theOCRReReadRefusesAnotherPersonsFolder() async throws {
        let (m, root) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = PersonVetoLog(userDefaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!)
        m.filingPersonVetoLog = log
        m.filingMemory = FilingMemory(profileId: "t", salt: "s", folders: [
            "Documents/Immigration/OCI/Son": FilingMemoryEntry(
                docs: 4, anchors: [FilingMemoryToken(token: "oci", weight: 4.0),
                                   FilingMemoryToken(token: "overseas", weight: 4.0)],
                idHashes: []),
        ])
        // The card the user clicks "read this scan" on: a nameless scan with no home yet.
        let scanPath = root.appendingPathComponent("Downloads/Scan 2026-08-02.pdf").path
        try Self.write(URL(fileURLWithPath: scanPath))
        m.filingLastProviderRoot = root.path
        m.prepareFilingRouter(destinations: ["Documents/Immigration/OCI/Son"],
                              providerRoot: root.path)
        m.filingOCRExtractor = { _ in "OCI Card Overseas Citizen of India — Daughter Father" }
        let card = FilingSuggestion(filePath: scanPath, fileName: "Scan 2026-08-02.pdf", size: 5000,
                                    modificationDate: nil, candidates: [], providerRoot: root.path)
        m.publishFilingSuggestions([card])

        let changed = await m.readScan(for: card)

        #expect(changed == false, "the re-read accepted a home in another person's folder")
        #expect(m.filingSuggestions.first?.candidates.isEmpty == true)
        #expect(log.events.first?.proposedPerson == "son")
    }
}
