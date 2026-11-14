import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// A tiny thread-safe flag for asserting whether an injected closure ran, and for releasing a
/// closure parked in another isolation domain. Lock-backed: it is written from a test and read
/// from an injected closure, and an unsynchronized `var` is a data race whose torn read could hang
/// a parked spin.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Parks an injected classifier closure until the test sets `released`, bounded so a mis-wired
/// test fails on its assertions instead of spinning until the CI job times out.
///
/// The bound's expiry is recorded in `timedOut`, never discarded: a park that quietly gives up
/// lets the round-trip complete before the test has staged its state, so the guard under test is
/// never evaluated and a positive control passes asserting nothing. As with `awaitSignal` and
/// ``FirstStatGate/releasedByTimeout``, callers must `#expect(!timedOut.value, …)` afterwards.
///
/// Bounded by ``parkTurnFloor`` scheduler turns as well as seconds: the parked closures run on
/// the cooperative pool (a classifier, or an operation `enqueueFileOperation` runs detached) while
/// the release comes from a main-actor test, so seconds alone run out under load first
/// (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). It sleeps rather than yields, so a held
/// park doesn't keep a pool thread busy.
func parkUntilReleased(_ released: Flag, timedOut: Flag, timeout: TimeInterval = 10) async {
    let deadline = TurnDeadline(seconds: timeout, turns: parkTurnFloor)
    while !released.value {
        if deadline.hasPassed { timedOut.value = true; return }
        // A cancelled task's sleep returns at once, so the yield is what keeps that loop polite.
        try? await Task.sleep(nanoseconds: 1_000_000)
        await Task.yield()
    }
}

/// Waits, on the main actor, for work the test launched to reach the classifier.
///
/// Bounded by ``signalTurnFloor`` scheduler turns as well as seconds, like ``parkUntilReleased``.
/// The classifier runs on the cooperative pool and this wait on the main actor, so a backed-up
/// pool could spend a plain deadline before the classifier ever started. A turn needs the pool as
/// well as the main actor, so a starved pool stops this clock instead (`docs/flaky-tests.md`, "A
/// park's bound counted seconds while its release waited for scheduler turns"). A timeout is
/// recorded with the seconds and turns spent.
@MainActor
func awaitArrival(_ what: Comment, timeout: TimeInterval = 10,
                  sourceLocation: SourceLocation = #_sourceLocation,
                  _ arrived: () -> Bool) async {
    let deadline = TurnDeadline(seconds: timeout, turns: signalTurnFloor)
    while !arrived() {
        if deadline.hasPassed {
            #expect(arrived(), "\(what.rawValue) — \(deadline.spent)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// A thread-safe call counter for injected closures, lock-backed for the same reason as ``Flag``:
/// written from a closure in another isolation domain and read from the test's spins.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    /// Increments and returns the new value, atomically, so concurrent callers each see a distinct
    /// ordinal.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

/// What the classifier was handed on a re-ask — recorded from a `@Sendable` closure, so it is a
/// lock-guarded box rather than a captured `var`.
private typealias SnippetBox = LockedBox<(tier: FilingClassifierTier?, snippet: String?)>

private extension LockedBox where Value == (tier: FilingClassifierTier?, snippet: String?) {
    convenience init() { self.init((nil, nil)) }
    func record(tier: FilingClassifierTier, snippet: String?) { withLock { $0 = (tier, snippet) } }
    var snippet: String? { withLock { $0.snippet } }
    var tier: FilingClassifierTier? { withLock { $0.tier } }
}

/// Filing at the manager level: the end-to-end scan over real folders, and the apply path (a real,
/// undoable move that creates new folders).
@Suite struct FileSyncManagerFilingTests {

    /// A manager for a "Try another" re-ask: its settings and rules on `defaults` (a scratch suite
    /// by default), and the provider-scoped cache naming `/p` with the `Docs` taxonomy.
    @MainActor private func reaskManager(defaults: UserDefaults = ScratchDefaults("FilingAI")) -> FileSyncManager {
        let manager = FileSyncManager()
        manager.filingContentDefaults = defaults
        manager.filingRuleDefaults = defaults
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        return manager
    }

    /// A card for `/p/Downloads/<name>` whose one candidate is `/p/Docs/A`.
    private func reaskCard(_ name: String) -> FilingSuggestion {
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        return FilingSuggestion(filePath: "/p/Downloads/\(name)", fileName: name,
                                size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
    }

    /// A classifier answer filing every file into a new `Docs/Fresh`.
    private static func freshVerdicts(_ files: [FilingCandidateFile]) -> [String: FilingVerdict] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
            FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai", proposesNewFolder: true)) })
    }

    @MainActor
    @Test func findFilingSuggestionsFindsHomesInYourFolders() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)   // existing Vehicles folder
        try writeBytes(root.appendingPathComponent("Downloads/Tesla Auto Policy.pdf"))
        try writeBytes(root.appendingPathComponent("Downloads/zxqw9.bin"))

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(manager.hasSuggestedFiling)
        let tesla = manager.filingSuggestions.first { $0.fileName.hasPrefix("Tesla") }
        #expect(tesla?.best?.path.hasSuffix("Documents/Vehicles/Tesla/Insurance") == true)
        #expect(tesla?.best?.newSegments == ["Tesla", "Insurance"])
        let junk = manager.filingSuggestions.first { $0.fileName == "zxqw9.bin" }
        #expect(junk?.hasConfidentHome == false)
    }

    @MainActor
    @Test func applyFilingMovesFileAndCreatesNewFolders() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try writeBytes(srcPath)

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: srcPath.path, fileName: "Tesla Policy.pdf",
                                          size: 5000, modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance").path,
                                     confidence: .medium, reasons: [], newSegments: ["Tesla", "Insurance"])
        manager.filingSuggestions = [suggestion]

        let ok = await manager.applyFilingSuggestion(suggestion, to: dest)

        let movedPath = root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance/Tesla Policy.pdf").path
        #expect(ok == .moved)
        #expect(FileManager.default.fileExists(atPath: movedPath))          // moved, new folders created
        #expect(!FileManager.default.fileExists(atPath: srcPath.path))      // gone from Downloads
        #expect(manager.filingSuggestions.isEmpty)                          // dropped from the list
        #expect(manager.banner?.severity == .success)
    }

    @MainActor
    @Test func applyRecommendedFilesConfidentOnlyLeavesTheRest() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Tesla Policy/.keep"), bytes: 1)   // High: two words
        try writeBytes(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
        let junkPath = root.appendingPathComponent("Downloads/zxqw9.bin")
        try writeBytes(junkPath)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(manager.filingSuggestions.count == 2)

        await manager.applyRecommendedFiling(manager.batchEligibleFilingSuggestions)

        // The unrecognized file stays put and stays in the list.
        #expect(FileManager.default.fileExists(atPath: junkPath.path))
        #expect(manager.filingSuggestions.count == 1)
        #expect(manager.filingSuggestions.first?.fileName == "zxqw9.bin")
    }

    /// How a destination can name the file's own folder.
    enum OwnFolderSpelling: Sendable { case same, caseVariant, link }

    /// The case-variant spelling only where the volume folds case: on a case-SENSITIVE volume
    /// these really are two folders, and filing into the second is a real move, not a no-op.
    static let ownFolderSpellings: [OwnFolderSpelling] =
        FileSyncManager.volumeSupportsCaseSensitiveNames(for: FileManager.default.temporaryDirectory)
            ? [.same, .link] : [.same, .caseVariant, .link]

    /// Filing into the file's own folder is a no-op success, not a move or a rename.
    ///
    /// Automation templates match case-insensitively, so "downloads" for the on-disk "Downloads"
    /// is expected input. Compared exactly, or through an unresolved symbolic link, it reads as a
    /// different folder: the move finds the file itself, the unique-name helper steps around it,
    /// and the file is renamed in place to "report 2.pdf" under a "Filed" banner.
    @MainActor
    @Test(arguments: Self.ownFolderSpellings)
    func applyingToTheFilesOwnFolderIsANoOpNotARename(_ spelling: OwnFolderSpelling) async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcPath = root.appendingPathComponent("Downloads/report.pdf")
        try writeBytes(srcPath)
        let destination: URL
        switch spelling {
        case .same: destination = root.appendingPathComponent("Downloads")
        case .caseVariant: destination = root.appendingPathComponent("downloads")
        case .link:
            destination = root.appendingPathComponent("Filing")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("Downloads"))
        }

        let manager = FileSyncManager()
        let s = FilingSuggestion(filePath: srcPath.path, fileName: "report.pdf", size: 5000,
                                 modificationDate: nil, candidates: [])
        manager.filingSuggestions = [s]
        let dest = FilingDestination(path: destination.path, confidence: .high, reasons: [], newSegments: [])

        let ok = await manager.applyFilingSuggestion(s, to: dest)

        #expect(ok == .notNeeded)
        #expect(FileManager.default.fileExists(atPath: srcPath.path))
        // The rename this guard exists to prevent: no "report 2.pdf" beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Downloads").path)
        #expect(names == ["report.pdf"], "the file was renamed in place: \(names)")
        #expect(manager.filingSuggestions.isEmpty)                                                      // dropped from list
        if spelling == .link {
            // The card goes with a word, or it looks like a click that did nothing.
            let banner = try #require(manager.banner, "the card vanished without a word")
            #expect(banner.message == "“report.pdf” is already in that folder — nothing to move.")
        }
    }

    /// The batch counts the files already in their folders. A suggestion naming a link to the
    /// file's own folder files as "nothing to move", and "File all" must still count it, or two
    /// cards go and the banner says one file was filed.
    @MainActor
    @Test func theBatchCountsFilesAlreadyInTheirFolder() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let here = root.appendingPathComponent("Downloads/report.pdf")
        let away = root.appendingPathComponent("Downloads/invoice.pdf")
        try writeBytes(here)
        try writeBytes(away)
        let bills = root.appendingPathComponent("Documents/Bills")
        try FileManager.default.createDirectory(at: bills, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Filing")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Downloads"))

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let cards = [
            FilingSuggestion(filePath: here.path, fileName: "report.pdf", size: 5000, modificationDate: nil,
                             candidates: [FilingDestination(path: link.path, confidence: .high,
                                                            reasons: ["by name"], newSegments: [])],
                             providerRoot: root.path),
            FilingSuggestion(filePath: away.path, fileName: "invoice.pdf", size: 5000, modificationDate: nil,
                             candidates: [FilingDestination(path: bills.path, confidence: .high,
                                                            reasons: ["by name"], newSegments: [])],
                             providerRoot: root.path),
        ]
        manager.publishFilingSuggestions(cards)
        let batch = manager.batchEligibleFilingSuggestions
        #expect(batch.count == 2, "the fixture needs both cards batch-eligible")

        await manager.applyRecommendedFiling(batch)

        #expect(FileManager.default.fileExists(atPath: bills.appendingPathComponent("invoice.pdf").path))
        let banner = try #require(manager.banner)
        #expect(banner.message.contains("Filed 1 file") && banner.message.contains("1 was already in its folder"),
                "the file already in its folder went uncounted: \(banner.message)")

        // Only files already home: still a word, not silence.
        let only = FilingSuggestion(filePath: here.path, fileName: "report.pdf", size: 5000, modificationDate: nil,
                                    candidates: [FilingDestination(path: link.path, confidence: .high,
                                                                   reasons: ["by name"], newSegments: [])],
                                    providerRoot: root.path)
        manager.banner = nil
        manager.publishFilingSuggestions([only])
        await manager.applyRecommendedFiling(manager.batchEligibleFilingSuggestions)
        #expect(manager.banner?.message == "1 file was already in its folder — nothing to move.")
    }

    /// The engine side of the same rule: a case-variant of the file's own parent must not even be
    /// OFFERED, or the user is invited to click a suggestion whose apply step declines.
    @Test func theEngineDropsACaseVariantOfTheFilesOwnParent() {
        let file = FileNode(id: "/root/Documents/Inbox/report.pdf", name: "report.pdf",
                            isDirectory: false, fileSize: 5000)
        let taxonomy = [
            FileNode(id: "/root/Documents", name: "Documents", isDirectory: true, children: [
                FileNode(id: "/root/Documents/Inbox", name: "Inbox", isDirectory: true, children: [])
            ])
        ]
        let rule = AutomationRule(name: "Reports", conditions: [.nameMatches("*report*")],
                                  destinationTemplate: "documents/inbox")

        let suggestions = FilingEngine.suggest(
            looseFiles: [file], taxonomy: taxonomy, providerRoot: "/root",
            automations: [rule], options: FilingOptions(caseSensitiveVolume: false))

        // Compared case-INSENSITIVELY on purpose: the rule spells the destination lowercase, so an
        // exact-match assertion would pass whether or not the filter works.
        func offersTheParent(_ result: [FilingSuggestion]) -> Bool {
            result.first?.candidates.contains {
                $0.path.caseInsensitiveCompare("/root/Documents/Inbox") == .orderedSame
            } ?? false
        }
        #expect(offersTheParent(suggestions) == false)
        // Control: on a case-sensitive volume the two really differ, so the candidate stands, which
        // proves the assertion above measures the filter, not a rule that never produced it.
        let sensitive = FilingEngine.suggest(
            looseFiles: [file], taxonomy: taxonomy, providerRoot: "/root",
            automations: [rule], options: FilingOptions(caseSensitiveVolume: true))
        #expect(offersTheParent(sensitive) == true)
    }

    @MainActor
    @Test func batchFilingIsASingleUndo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // Two words in common with each folder, so both are High and batched.
        try writeBytes(root.appendingPathComponent("Documents/Tesla Policy/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Documents/Toyota Registration/.keep"), bytes: 1)
        let tesla = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        let toyota = root.appendingPathComponent("Downloads/Toyota Registration.pdf")
        try writeBytes(tesla); try writeBytes(toyota)

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(manager.filingSuggestions.filter { $0.isBatchEligible }.count == 2)

        await manager.applyRecommendedFiling(manager.batchEligibleFilingSuggestions)
        #expect(!FileManager.default.fileExists(atPath: tesla.path))
        #expect(!FileManager.default.fileExists(atPath: toyota.path))

        // One ⌘Z reverts the whole batch.
        #expect(undo.canUndo)
        undo.undo()
        await waitUntil("both files restored") {
            FileManager.default.fileExists(atPath: tesla.path) && FileManager.default.fileExists(atPath: toyota.path)
        }
    }

    @MainActor
    @Test func batchSkipsContentDerivedSuggestions() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/scan0012.pdf")
        try writeBytes(srcPath)

        let manager = FileSyncManager()
        manager.filingContentExtractor = { $0.hasSuffix("scan0012.pdf") ? ["tesla", "policy", "geico"] : [] }
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let scan = manager.filingSuggestions.first { $0.fileName == "scan0012.pdf" }
        #expect(scan?.hasConfidentHome == true)     // content gave it a home
        #expect(scan?.best?.path.hasSuffix("Documents/Vehicles/Tesla/Insurance") == true)
        #expect(scan?.best?.reasons.first?.contains("read from the file") == true)
        #expect(scan?.isBatchEligible == false)     // but content-derived → not batch-eligible

        await manager.applyRecommendedFiling(manager.batchEligibleFilingSuggestions)
        #expect(FileManager.default.fileExists(atPath: srcPath.path))   // the batch did NOT move it
    }

    @MainActor
    @Test func readContentsToggleOffSkipsExtraction() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/scan0012.pdf"))

        let manager = FileSyncManager()
        manager.filingContentDefaults = ScratchDefaults("FilingToggle")
        manager.filingContentDefaults.set(false, forKey: FileSyncManager.readContentsDefaultsKey)
        // An extractor that WOULD give a home — proving it isn't consulted when the toggle is off.
        manager.filingContentExtractor = { _ in ["tesla", "policy"] }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let scan = manager.filingSuggestions.first { $0.fileName == "scan0012.pdf" }
        #expect(scan?.hasConfidentHome == false)   // stayed no-home → contents were not read
    }

    @MainActor
    @Test func clearFilingResetsState() {
        let manager = FileSyncManager()
        manager.filingSuggestions = [FilingSuggestion(filePath: "/a/x", fileName: "x", size: 1,
                                                      modificationDate: nil, candidates: [])]
        manager.filingScanFolder = "/a"
        manager.hasSuggestedFiling = true
        manager.filingSessionRejections = ["/a/x": ["/a/Docs"]]

        manager.clearFiling()

        #expect(manager.filingSuggestions.isEmpty)
        #expect(manager.filingScanFolder == nil)
        #expect(manager.hasSuggestedFiling == false)
        // Session rejections are keyed by file path, and another provider can host a same-named
        // path, so a provider switch must drop them.
        #expect(manager.filingSessionRejections.isEmpty)
    }

    /// "Try another" on a file whose name has no salient tokens ("IMG 0007", exactly the files the
    /// content/AI pipeline exists for) can't persist a token-keyed rejection, but the click must
    /// still take effect: the rejected folder never comes back for that file.
    @MainActor
    @Test func tryAnotherAdvancesForTokenlessFilenames() async throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("tryAnotherTokenless")
        let first = FilingDestination(path: "/root/A", confidence: .medium, reasons: [], newSegments: [])
        let second = FilingDestination(path: "/root/B", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/root/Loose/IMG 0007.pdf", fileName: "IMG 0007.pdf", size: 1,
                                 modificationDate: nil, candidates: [first, second], providerRoot: "/root")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)
        #expect(manager.filingSuggestions.first?.best?.path == "/root/B", "first rejection advances to the next candidate")

        let advanced = try #require(manager.filingSuggestions.first)
        await manager.tryAnotherFolder(for: advanced)
        // Both candidates rejected; no classifier is wired, so the card falls back to "Choose a folder…".
        #expect(manager.filingSuggestions.first?.candidates.isEmpty == true, "a rejected folder must never be re-offered")
    }

    // MARK: Remembered rules (F3)

    /// Points the manager's rule store at a `ScratchDefaults` suite, wiped once the manager lets go
    /// of it, so tests never touch standard defaults.
    @MainActor private func manager(withScratchRules prefix: String) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults(prefix)
        return m
    }

    @MainActor
    @Test func applyingWithRememberPersistsAReusableRule() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Archive/Tesla/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try writeBytes(srcPath)

        let manager = manager(withScratchRules: "FilingRules")

        let s = FilingSuggestion(filePath: srcPath.path, fileName: "Tesla Policy.pdf", size: 5000,
                                 modificationDate: nil, candidates: [])
        manager.filingSuggestions = [s]
        let dest = FilingDestination(path: root.appendingPathComponent("Archive/Tesla").path,
                                     confidence: .high, reasons: [], newSegments: [])
        _ = await manager.applyFilingSuggestion(s, to: dest, remember: true)

        #expect(manager.automationRules.count == 1)
        #expect(manager.automationRules.first?.conditions == [.mentionsAll(["tesla"])])

        // A fresh scan files another Tesla file into the remembered folder, high-confidence and
        // batch-eligible.
        try writeBytes(root.appendingPathComponent("Downloads/tesla renewal 2025.pdf"))
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let renewal = manager.filingSuggestions.first { $0.fileName.hasPrefix("tesla renewal") }
        #expect(renewal?.best?.path == root.appendingPathComponent("Archive/Tesla").path)
        #expect(renewal?.best?.remembered == true)
        #expect(renewal?.isBatchEligible == true)
    }

    @MainActor
    @Test func rememberingCreatesAMentionsAutomation() {
        let manager = manager(withScratchRules: "RememberAuto")

        // A learned rule stores the ABSOLUTE folder it filed into, so it can never batch-file into
        // another provider.
        let rule = manager.rememberAutomationRule(fileName: "Tesla Policy.pdf",
                                                  destinationPath: "/p/Vehicles/Tesla")
        #expect(rule?.conditions == [.mentionsAll(["tesla"])])
        #expect(rule?.destinationTemplate == "/p/Vehicles/Tesla")
        #expect(rule?.enabled == true)
        #expect(manager.automationRules.count == 1)

        // A nameless file (IMG_0007 → no usable tokens) yields nothing to key on — nothing learned.
        #expect(manager.rememberAutomationRule(fileName: "IMG_0007.pdf", destinationPath: "/p/Misc") == nil)
        #expect(manager.automationRules.count == 1)

        // Re-teaching the same trigger replaces the destination rather than duplicating,
        // without touching an unrelated rule.
        manager.upsertAutomationRule(AutomationRule(name: "Other", conditions: [.kindIs(.pdf)],
                                                    destinationTemplate: "Docs"))
        let retaught = manager.rememberAutomationRule(fileName: "Tesla Card.pdf",
                                                      destinationPath: "/p/Cars/Tesla")
        #expect(retaught?.destinationTemplate == "/p/Cars/Tesla")
        #expect(manager.automationRules.count == 2)
        #expect(manager.automationRules.contains { $0.name == "Other" })
    }

    /// `setAutomationRule` with the stored value is a no-op: no re-persist and no duplicate
    /// "enabled/disabled" audit-log line, whoever calls it.
    @MainActor
    @Test func settingAnUnchangedEnabledStateDoesNotDoubleLog() async {
        let log = LogCapture()
        let manager = manager(withScratchRules: "SetRuleNoOp")

        let rule = AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                                  destinationTemplate: "Cars/Tesla")
        manager.upsertAutomationRule(rule)

        // Counted in a capture opened when the test began, so a count can only grow: counted in the
        // shared buffer, the rest of the package logging past the baseline's lines could shrink it.
        func logCount(_ message: String) async -> Int {
            await log.entries.filter { $0.message == message }.count
        }
        let disabledLine = "Automation rule disabled: “Tesla”"
        let baseline = await logCount(disabledLine)

        manager.setAutomationRule(id: rule.id, enabled: false)
        #expect(manager.automationRules.first?.enabled == false)
        #expect(await logCount(disabledLine) == baseline + 1)

        // Repeating the same value logs nothing.
        manager.setAutomationRule(id: rule.id, enabled: false)
        #expect(manager.automationRules.first?.enabled == false)
        #expect(await logCount(disabledLine) == baseline + 1)
    }

    /// An automation with an absolute destination pointing into a different provider must never
    /// steer this provider's scan.
    @MainActor
    @Test func automationsAreScopedToTheProviderTheyPointInto() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Downloads/tesla thing.pdf"))

        let manager = manager(withScratchRules: "AutoScope")
        manager.upsertAutomationRule(AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                                                    destinationTemplate: "/SomeOtherProvider/Cars"))

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let s = manager.filingSuggestions.first { $0.fileName == "tesla thing.pdf" }
        #expect(!(s?.candidates.contains { $0.remembered } ?? false))
    }

    /// An authored automation (kind-based, relative destination with a {provider} token) steers the
    /// scan: name/metadata-derived, so high confidence and batch-eligible; the token resolves from
    /// the scan's provider name — and stays inert when no provider name is known.
    @Test func authoredAutomationSteersWithProviderToken() {
        let file = FileNode(id: "/p/Inbox/report.pdf", name: "report.pdf", isDirectory: false,
                            children: nil, modificationDate: Date(), fileSize: 5000)
        let rule = AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)],
                                  destinationTemplate: "Filed/{provider}")

        let steered = FilingEngine.suggest(looseFiles: [file], taxonomy: [], providerRoot: "/p",
                                           automations: [rule], providerName: "iCloud")
        #expect(steered.first?.best?.path == "/p/Filed/iCloud")
        #expect(steered.first?.best?.remembered == true)
        #expect(steered.first?.best?.confidence == .high)
        #expect(steered.first?.isBatchEligible == true)

        // {provider} with no provider name → the rule can't resolve, so it steers nothing.
        let unresolved = FilingEngine.suggest(looseFiles: [file], taxonomy: [], providerRoot: "/p",
                                              automations: [rule], providerName: nil)
        #expect(!(unresolved.first?.candidates.contains { $0.remembered } ?? false))
    }

    /// The Organize scan hands suggest() the extractor's RAW text while the dry-run preview
    /// lowercases before evaluating — one rule must answer the same on both surfaces. The choke
    /// point (automationFacts) lowercases, so a PDF whose text reads "Invoice #4321" (no
    /// lowercase occurrence anywhere) still matches `text contains "invoice"` in the scan.
    @Test func contentContainsMatchesRawCapitalizedScanSnippets() {
        let file = FileNode(id: "/p/Inbox/scan9.pdf", name: "scan9.pdf", isDirectory: false,
                            children: nil, modificationDate: Date(), fileSize: 5000)
        let rule = AutomationRule(name: "Invoices", conditions: [.contentContains("invoice")],
                                  destinationTemplate: "/p/Invoices")
        let steered = FilingEngine.suggest(looseFiles: [file], taxonomy: [], providerRoot: "/p",
                                           automations: [rule],
                                           automationSnippets: [file.id: "Invoice #4321 — Total Due"])
        #expect(steered.first?.best?.path == "/p/Invoices")
        #expect(steered.first?.best?.fromContent == true)   // content-derived → medium, no blind batch
    }

    /// A mixed match of a learned rule (one trigger word in the name) counts as name-derived, high
    /// confidence and batch-eligible. A content-only match is pinned in `FilingProvenancePinTests`.
    @Test func aMixedRuleMatchCountsAsNameDerived() {
        let mixedRule = AutomationRule(name: "Acme", conditions: [.mentionsAll(["acme", "invoice"])],
                                       destinationTemplate: "/p/Acme")
        let mixedFile = FileNode(id: "/p/Inbox/acme-2025.pdf", name: "acme-2025.pdf", isDirectory: false,
                                 children: nil, modificationDate: Date(), fileSize: 5000)
        let mixed = FilingEngine.suggest(looseFiles: [mixedFile], taxonomy: [], providerRoot: "/p",
                                         contentTokens: [mixedFile.id: ["invoice"]],
                                         automations: [mixedRule])
        #expect(mixed.first?.best?.confidence == .high)
        #expect(mixed.first?.best?.fromContent == false)
        #expect(mixed.first?.isBatchEligible == true)
    }

    /// The Organize scan reads a file's text for content rules with the same gating the preview
    /// uses, so a rule that matches a file in the lens matches it in the scan — one rule, one
    /// answer. Files no content rule could flip are never read.
    @MainActor
    @Test func scanExtractsSnippetsForContentRulesLikeThePreview() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Inbox/scan0001.pdf"))
        try writeBytes(root.appendingPathComponent("Inbox/tesla-note.pdf"))

        let manager = manager(withScratchRules: "SnippetParity")
        manager.upsertAutomationRule(AutomationRule(name: "Lease", conditions: [.mentionsAll(["lease"])],
                                                    destinationTemplate: root.appendingPathComponent("Home/Lease").path))

        // "lease" is a generic word the sparse entity extractor would never surface — only the
        // raw text knows it. The name-matched file must NOT be read (its rule outcome can't flip).
        let read = LockedBox<[String]>([])
        manager.filingSnippetExtractor = { path in
            read.withLock { $0.append(path) }
            return path.hasSuffix("scan0001.pdf") ? "lease agreement for unit 4" : nil
        }
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"), providerRoot: root)

        let steered = manager.filingSuggestions.first { $0.fileName == "scan0001.pdf" }
        #expect(steered?.best?.path == root.appendingPathComponent("Home/Lease").path)
        #expect(steered?.best?.remembered == true)
        #expect(steered?.best?.fromContent == true)
        let paths = read.withLock { $0 }
        #expect(paths.contains { $0.hasSuffix("scan0001.pdf") })
    }

    @MainActor
    @Test func rejectionsPersistMatchAndClear() {
        let manager = manager(withScratchRules: "FilingRej")   // rejections share filingRuleDefaults

        #expect(manager.rememberFilingRejection(fileName: "Tesla Policy.pdf", destinationPath: "/p/Archive/Old"))
        #expect(manager.filingRejections.count == 1)
        // A same-signature file inherits the rejection; an unrelated one doesn't.
        #expect(FileSyncManager.rejectedPaths(forFileNamed: "Tesla Policy 2025.pdf", in: manager.filingRejections).contains("/p/Archive/Old"))
        #expect(FileSyncManager.rejectedPaths(forFileNamed: "Geico Bill.pdf", in: manager.filingRejections).isEmpty)
        // A nameless file can't seed a rejection.
        #expect(manager.rememberFilingRejection(fileName: "IMG_0007.pdf", destinationPath: "/p/x") == false)

        manager.clearFilingRejections()
        #expect(manager.filingRejections.isEmpty)
    }

    // MARK: Intelligent classifier (AI)

    @MainActor
    @Test func classifierNeverSeesIgnoredOrUndersizedFiles() async throws {
        // Phase 3 must apply the engine's ignoredNames/minFileSize filters. Unfiltered, ".DS_Store"
        // goes into the paid classifier request (its name in the prompt, its slot against the
        // 150-file cloud / 25-file on-device cap), its verdict is discarded since no suggestion
        // exists for it, and junk-heavy folders push real files past the cap.
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Stuff/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/.DS_Store"), bytes: 500)
        try writeBytes(root.appendingPathComponent("Downloads/mystery-scan-0042.pdf"))

        let seen = LockedBox<[String]>([])
        let manager = FileSyncManager()
        manager.filingClassifier = { _, files, _ in
            seen.withLock { $0 = files.map(\.fileName) }
            return [:]
        }
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(seen.withLock { $0 }.contains("mystery-scan-0042.pdf"))   // real files still classified
        #expect(!seen.withLock { $0 }.contains(".DS_Store"))              // junk never reaches the model
    }

    @MainActor
    @Test func classifierVerdictDrivesTheSuggestion() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Family/Son/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/Physician's Report - Son.pdf"))

        let manager = FileSyncManager()
        manager.filingClassifier = { context, files, _ in
            #expect(context.taxonomyFolders.contains("Documents/Family/Son"))  // the real taxonomy
            // With no profile loaded, destinations is the taxonomy unchanged, so a never-surveyed
            // machine sends a backend what it always did.
            #expect(context.destinations == context.taxonomyFolders)
            #expect(context.profile == nil)
            var out: [String: FilingVerdict] = [:]
            for f in files where f.fileName.contains("Son") {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Son",
                                                confidence: .high, reason: "Son’s medical record")
            }
            return out
        }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let s = manager.filingSuggestions.first { $0.fileName.contains("Son") }
        #expect(s?.best?.path == root.appendingPathComponent("Documents/Family/Son").path)
        #expect(s?.best?.fromAI == true)
        #expect(s?.best?.reasons.first == "Son’s medical record")
    }

    @MainActor
    @Test func aiToggleOffSkipsTheClassifier() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Downloads/mystery.pdf"))

        let manager = FileSyncManager()
        manager.filingContentDefaults = ScratchDefaults("FilingAI")
        manager.filingContentDefaults.set(false, forKey: FileSyncManager.usesAIDefaultsKey)
        // A classifier that WOULD give a home — proving it isn't consulted when AI is off.
        let consulted = Flag()
        manager.filingClassifier = { _, files, _ in
            consulted.value = true
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Documents", confidence: .high, reason: "x")) })
        }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(consulted.value == false)
        #expect(manager.filingSuggestions.first { $0.fileName == "mystery.pdf" }?.best?.fromAI != true)
    }

    // MARK: "Try another" (provider-scoped cache)

    /// The cached root/taxonomy for single-file re-asks must belong to THIS suggestion's provider:
    /// a scan of another provider (even a cancelled one) overwrites the cache, and resolving
    /// against it would move the file into the wrong provider's tree.
    @MainActor
    @Test func tryAnotherFolderIgnoresAnotherProvidersCachedTaxonomy() async throws {
        let manager = reaskManager()
        let consulted = Flag()
        manager.filingClassifier = { _, _, _ in consulted.value = true; return [:] }
        manager.filingLastProviderRoot = "/other"          // stale: another provider's scan
        let s = reaskCard("IMG_0008.HEIC")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        #expect(consulted.value == false, "must not resolve against the wrong provider's taxonomy")
        #expect(manager.filingSuggestions.first?.candidates.isEmpty == true, "falls back to Choose a folder…")
    }

    @MainActor
    @Test func tryAnotherFolderReasksBackendWhenCacheMatchesProvider() async throws {
        let manager = reaskManager()                       // the cache belongs to this provider
        manager.filingClassifier = { _, files, _ in Self.freshVerdicts(files) }
        let s = reaskCard("IMG_0009.HEIC")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        let best = manager.filingSuggestions.first?.best
        #expect(best?.path == "/p/Docs/Fresh")
        #expect(best?.fromAI == true)
        #expect(best?.newSegments == ["Fresh"])
    }

    /// The cached existing/taxonomy folder sets must not be re-read after the classifier await: a
    /// Filing scan of another provider (or `clearFiling()`) during the round-trip swaps or empties
    /// them, and a verdict labeled against the swapped set marks every segment new, so "Creates N
    /// new folders." lies. Label against the sets snapshotted where the provider root was validated.
    @MainActor
    @Test func tryAnotherFolderLabelsVerdictAgainstPreAwaitSnapshot() async throws {
        let manager = reaskManager()
        manager.filingClassifier = { _, files, _ in
            // Another provider's scan lands while the classifier is out: it overwrites every
            // cached set (clearFiling would empty them — same failure shape).
            await MainActor.run {
                manager.filingLastProviderRoot = "/other"
                manager.filingLastTaxonomyFolders = ["Zebra"]
                manager.filingLastExistingFolders = ["Zebra"]
            }
            return Self.freshVerdicts(files)
        }
        // "Docs/Fresh" already exists (captured beyond the classifier cap) — nothing to create.
        manager.filingLastExistingFolders = ["Docs", "Docs/Fresh"]
        let s = reaskCard("IMG_0010.HEIC")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        let best = manager.filingSuggestions.first?.best
        #expect(best?.path == "/p/Docs/Fresh")
        #expect(best?.newSegments == [], "labeled against the snapshot: Docs/Fresh existed when the re-ask was issued")
    }

    /// The other arm of the same snapshot rule: when the full existing-folder set was never
    /// captured, labeling falls back to the (capped) taxonomy list, which must be the pre-await
    /// snapshot too. The test above always has `filingLastExistingFolders`, so only this one fails
    /// if the fallback reads `filingLastTaxonomyFolders` live.
    @MainActor
    @Test func tryAnotherFolderFallsBackToTheSnapshottedTaxonomyList() async throws {
        let manager = reaskManager()
        manager.filingClassifier = { _, files, _ in
            // Another provider's scan lands mid-round-trip and swaps the taxonomy list.
            await MainActor.run {
                manager.filingLastProviderRoot = "/other"
                manager.filingLastTaxonomyFolders = ["Zebra"]
            }
            return Self.freshVerdicts(files)
        }
        // Both folders already exist, and only the taxonomy list knows it — the full set was
        // never captured, which is exactly what puts the fallback arm in play.
        manager.filingLastTaxonomyFolders = ["Docs", "Docs/Fresh"]
        manager.filingLastExistingFolders = []
        let s = reaskCard("IMG_0012.HEIC")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        let best = manager.filingSuggestions.first?.best
        #expect(best?.path == "/p/Docs/Fresh")
        #expect(best?.newSegments == [],
                "the fallback must use the taxonomy list snapshotted pre-await, not the swapped one")
    }

    // MARK: - The paid re-ask must not go out blind

    /// "Try another" is a `.refine` call, the paid tier, so it sends the file's content snippet: a
    /// name-only verdict is one the overlay refuses anyway (`contentBlind`). The page is free:
    /// `filingPageSamples` holds page 1 of every file the scan read.
    @MainActor
    @Test func tryAnotherFolderSendsThePageTheScanAlreadyRead() async throws {
        let manager = reaskManager()

        let seen = SnippetBox()
        manager.filingClassifier = { _, files, tier in
            seen.record(tier: tier, snippet: files.first?.contentSnippet)
            return Self.freshVerdicts(files)
        }
        let s = reaskCard("Scan.pdf")
        manager.publishFilingSuggestions([s])
        manager.filingPageSamples["/p/Downloads/Scan.pdf"] =
            "eOCI Card | Government of India | Bureau of Immigration"

        await manager.tryAnotherFolder(for: s)

        #expect(seen.snippet == "eOCI Card | Government of India | Bureau of Immigration",
                "the paid re-ask went out with no content, so the overlay can refuse the verdict it paid for")
        // The premise: this really is the paid tier, which is what makes a blind ask cost money.
        #expect(seen.tier == .refine)
    }

    /// A file the scan never read still sends nil — the honest answer for it, and the guard must
    /// not invent an excerpt to avoid one.
    @MainActor
    @Test func tryAnotherFolderSendsNilForAFileWithNoPageSample() async throws {
        let manager = reaskManager()

        let seen = SnippetBox()
        manager.filingClassifier = { _, files, tier in
            seen.record(tier: tier, snippet: files.first?.contentSnippet)
            return [:]
        }
        let s = reaskCard("IMG_0023.HEIC")
        manager.publishFilingSuggestions([s])

        await manager.tryAnotherFolder(for: s)
        #expect(seen.snippet == nil)
    }

    // MARK: - The re-ask is billable, so it answers to the limit

    /// Clicks "Try another" on `Scan.pdf` with the cloud backend on the chat's model, and `limit` as
    /// Ask Claude's monthly limit when given. Returns the manager and what the classifier was handed.
    @MainActor
    private func cloudReask(_ prefix: String, limit: Double? = nil) async -> (FileSyncManager, SnippetBox) {
        let defaults = ScratchDefaults(prefix)
        if let limit { defaults.set(limit, forKey: AskClaudeSpend.limitDefaultsKey) }

        let manager = reaskManager(defaults: defaults)
        manager.filingCloudRefineConfigured = { true }
        manager.filingBackendIdentity = { _ in "cloud:\(AskClaudeModels.defaultModel.id)" }

        let seen = SnippetBox()
        manager.filingClassifier = { _, files, tier in
            seen.record(tier: tier, snippet: files.first?.contentSnippet)
            return [:]
        }
        let s = reaskCard("Scan.pdf")
        manager.publishFilingSuggestions([s])

        await manager.tryAnotherFolder(for: s)
        return (manager, seen)
    }

    /// A re-ask past the limit refuses, puts the remedy in a banner (no modal per card click), and
    /// keeps the free on-device suggestion. The banner is asserted, not just the refusal: a silent
    /// refusal with the remedy only in `~/sync-cloud.log` passes a check on the classifier alone.
    @MainActor
    @Test func tryAnotherFolderStandsDownWhenTheLimitWouldBePassed() async throws {
        // A limit below the cost of any real call, so one priced file passes it. Seeding spend just
        // under the shipped $25 wouldn't: a one-file estimate is a fraction of a cent. This makes the
        // estimate matter without depending on a model's price.
        let (manager, seen) = await cloudReask("reaskCap", limit: 0.0001)

        #expect(seen.tier == nil, "the re-ask reached the paid classifier with the limit already passed")
        let banner = try #require(manager.banner, "the refused re-ask left the user no sign at all")
        #expect(banner.severity == .warning)
        #expect(banner.message.contains("monthly Claude limit"),
                "the banner does not say why the click declined: \(banner.message)")
        #expect(banner.message.contains("Settings"),
                "the banner does not name the remedy: \(banner.message)")
        // Nothing was sent: a refusal, kept for this session only.
        #expect(banner.isRefusal)
    }

    /// And it still runs when there is room: the guard must not become "never re-ask". Same
    /// fixture with no recorded spend, so the same click goes through to the paid tier.
    @MainActor
    @Test func tryAnotherFolderStillRunsWhenTheCapsHaveRoom() async throws {
        let (manager, seen) = await cloudReask("reaskRoom")

        #expect(seen.tier == .refine, "a re-ask with budget left was refused")
        // No banner on the ordinary path: a warning on every re-ask trains the user to ignore it.
        #expect(manager.banner == nil, "a re-ask that went through posted a banner anyway")
    }

    /// Each "Try another" click fires its own unstructured Task; without a guard two rapid
    /// clicks run two classifier round-trips for the same card and whichever RETURNS last wins.
    /// A second call while the first is parked at the classifier must be a no-op.
    @MainActor
    @Test func tryAnotherFolderIgnoresReentrantCallForSameSuggestion() async throws {
        let manager = reaskManager()

        let calls = CallCounter()
        let released = Flag()
        let parkTimedOut = Flag()
        manager.filingClassifier = { _, files, _ in
            // Only the first round-trip parks: a second one (what this test forbids) returns at
            // once, so a regression fails the call-count check below instead of deadlocking the
            // suite on a release that never comes.
            if calls.next() == 1 {
                await parkUntilReleased(released, timedOut: parkTimedOut)
            }
            return Self.freshVerdicts(files)
        }
        let s = reaskCard("IMG_0011.HEIC")
        manager.filingSuggestions = [s]

        let first = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        // Let the first call reach the classifier and park there (bounded, same reason).
        await awaitArrival("the first re-ask must reach the classifier") { calls.value != 0 }
        #expect(calls.value == 1, "the first re-ask must reach the classifier")

        await manager.tryAnotherFolder(for: s)   // the second rapid click
        #expect(calls.value == 1, "a re-entrant Try another for the same card must not start a second round-trip")

        released.value = true
        await first.value
        #expect(!parkTimedOut.value,
                "the park timed out: the first round-trip returned on its own, so the re-entrant click was never made against an in-flight re-ask")
        #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/Fresh")
        #expect(manager.filingTryAnotherInFlight.isEmpty, "the completed re-ask must release its id")

        // The latch opens again: a click after the first round-trip returned reaches the
        // classifier. Fails if `tryAnotherFolder`'s releasing `defer` is deleted.
        let refreshed = try #require(manager.filingSuggestions.first)
        await manager.tryAnotherFolder(for: refreshed)
        #expect(calls.value == 2, "once the first re-ask returned, the next click must re-ask again")
    }

    /// `tryAnotherFolder` releases its in-flight id in a `defer`, but only if it returns, and
    /// `FilingClassifier` has no timeout: a round-trip that never returns latches the id, and every
    /// later "Try another" for that card silently does nothing. `clearFiling()` (switching
    /// providers) is the way out, so it clears the set along with the rest of the filing state.
    @MainActor
    @Test func clearFilingReleasesStuckTryAnotherIds() async throws {
        let manager = FileSyncManager()
        manager.filingTryAnotherInFlight = ["/p/Downloads/Stuck.pdf": UUID()]

        manager.clearFiling()

        #expect(manager.filingTryAnotherInFlight.isEmpty,
                "a classifier round-trip that never returns must not latch the card forever")
    }

    /// The recovery hatch must not re-arm the race it recovers from. `filingTryAnotherInFlight` is
    /// keyed by suggestion id, the file's absolute path, stable across scans. After round-trip A
    /// wedges, `clearFiling()` releases /X, a rescan recreates the card under the same id, and a
    /// click starts B. If A's late `defer` released unconditionally it would strip B's guard, and a
    /// third click would run beside B. A stale invocation may release only its own entry.
    @MainActor
    @Test func staleTryAnotherDeferMustNotReleaseTheNewRoundTripsGuard() async throws {
        let manager = reaskManager()

        let calls = CallCounter()
        let releaseA = Flag()
        let releaseB = Flag()
        let parkATimedOut = Flag()
        let parkBTimedOut = Flag()
        manager.filingClassifier = { _, files, _ in
            // Round-trip A parks on its own gate, B on its own; anything later (what this test
            // forbids) returns at once, so a regression fails the call-count check below instead
            // of deadlocking the suite. Bounded parks, same reason.
            switch calls.next() {
            case 1: await parkUntilReleased(releaseA, timedOut: parkATimedOut)
            case 2: await parkUntilReleased(releaseB, timedOut: parkBTimedOut)
            default: break
            }
            return Self.freshVerdicts(files)
        }
        let s = reaskCard("IMG_0020.HEIC")
        manager.filingSuggestions = [s]

        // Round-trip A reaches the classifier and parks there (wedged — no timeout exists).
        let a = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        await awaitArrival("round-trip A must reach the classifier") { calls.value != 0 }
        #expect(calls.value == 1, "round-trip A must reach the classifier")

        // The user switches providers away and back (clearFiling releases /X), and a rescan
        // recreates the card under the same id.
        manager.clearFiling()
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        manager.publishFilingSuggestions([s])

        // Round-trip B starts for the recreated card and parks in turn.
        let b = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        await awaitArrival("round-trip B must reach the classifier") { calls.value >= 2 }
        #expect(calls.value == 2, "round-trip B must reach the classifier")
        #expect(manager.filingTryAnotherInFlight[s.id] != nil, "B's re-ask is out, so its guard is armed")

        // A finally returns. Its defer is stale — it must NOT release B's guard.
        releaseA.value = true
        await a.value
        #expect(!parkATimedOut.value,
                "A's park timed out: A returned before clearFiling ran, so its defer was never stale and the check below describes B's own release")
        #expect(manager.filingTryAnotherInFlight[s.id] != nil,
                "A's stale defer released B's still-out guard — the ownership check is gone")

        // And with B still out, another click must be refused, not start a third round-trip.
        let recreated = try #require(manager.filingSuggestions.first)
        await manager.tryAnotherFolder(for: recreated)
        #expect(calls.value == 2,
                "a click while B is still out must be refused; a third concurrent round-trip is the raced bug")

        // B returns: its own defer releases its own entry, and its verdict lands as usual.
        releaseB.value = true
        await b.value
        #expect(!parkBTimedOut.value, "B's park timed out — B was not still out for the refused click above")
        #expect(manager.filingTryAnotherInFlight[s.id] == nil, "B's completed re-ask must release its own entry")
        #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/Fresh",
                "the CURRENT round-trip's verdict still lands")
    }

    /// What moves the filing state on while round-trip A is parked at the classifier.
    enum MidReaskChange: Sendable { case clearAndRecreate, completedRescan, cancelledRescan }

    /// A late "Try another" RESULT lands only in the cards it was computed against.
    ///
    /// `clearAndRecreate`: `replaceFilingSuggestion` keys on the suggestion id, the stable file
    /// path, so after clearFiling + rescan recreate the card, A's verdict, computed against the
    /// pre-clear state, lands in the new session's card. A verdict from an invocation that no
    /// longer owns its in-flight entry must be dropped.
    ///
    /// `completedRescan`: a rescan assigns `filingSuggestions` without touching
    /// `filingTryAnotherInFlight`, so an ownership check alone lets the stale write through. A
    /// completed rescan moves `filingSuggestionsGeneration`, bumped with the publish, and that
    /// must gate the result write.
    ///
    /// `cancelledRescan`, the other side of that guard: drop a verdict only when the list really
    /// was republished. A cancelled rescan bumps the epoch twice (`beginScan`, then `endScan` in
    /// the scan's `defer`) without publishing, leaving the old cards standing; gating on the epoch
    /// would throw away a verdict about exactly the cards on screen, and the card would keep the
    /// folder the user just rejected. This is a positive control, so it needs the timeout check: a
    /// park that gave up lets A complete before the epoch moved, and the assertion passes vacuously.
    @MainActor
    @Test(arguments: [MidReaskChange.clearAndRecreate, .completedRescan, .cancelledRescan])
    func aLateTryAnotherResultLandsOnlyInTheCardsItWasComputedAgainst(_ change: MidReaskChange) async throws {
        let manager = reaskManager()

        let calls = CallCounter()
        let releaseA = Flag()
        let parkTimedOut = Flag()
        manager.filingClassifier = { _, files, _ in
            if calls.next() == 1 {
                await parkUntilReleased(releaseA, timedOut: parkTimedOut)
            }
            return Self.freshVerdicts(files)
        }
        let names: [MidReaskChange: String] = [.clearAndRecreate: "IMG_0021.HEIC", .completedRescan: "IMG_0022.HEIC",
                                               .cancelledRescan: "IMG_0023.HEIC"]
        let s = reaskCard(names[change]!)
        if change == .cancelledRescan {
            manager.publishFilingSuggestions([s])
        } else {
            manager.filingSuggestions = [s]
        }

        let a = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        await awaitArrival("round-trip A must reach the classifier") { calls.value != 0 }
        #expect(calls.value == 1, "round-trip A must reach the classifier")

        switch change {
        case .clearAndRecreate:
            // Provider switch releases A's entry; the rescan recreates the card — same id, fresh
            // session state.
            manager.clearFiling()
            manager.filingLastProviderRoot = "/p"
            manager.filingLastTaxonomyFolders = ["Docs"]
            manager.publishFilingSuggestions([s])
        case .completedRescan:
            // A rescan runs to completion while A is parked, as the real state machine does: begin,
            // the one publish that recreates the card, then the `defer`'s end.
            manager.beginScan(\.filingScanLifecycle, status: "Rescanning…")
            manager.publishFilingSuggestions([s])
            manager.endScan(\.filingScanLifecycle)
        case .cancelledRescan:
            // A rescan starts and is CANCELLED while A is parked: `beginScan` bumps the epoch, the
            // scan body's `defer` runs `endScan` and bumps it again, and the publish at the end of
            // `findFilingSuggestions` is never reached — every `Task.isCancelled` return is above
            // it. The cards on screen are still A's.
            manager.beginScan(\.filingScanLifecycle, status: "Rescanning…")
            manager.endScan(\.filingScanLifecycle)
        }

        releaseA.value = true
        await a.value
        switch change {
        case .clearAndRecreate:
            #expect(!parkTimedOut.value,
                    "the park timed out: A's verdict landed before clearFiling + the rescan recreated the card, so the ownership guard was never exercised")
            #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/A",
                    "a verdict computed against the pre-clear session must not land in the recreated card")
        case .completedRescan:
            #expect(!parkTimedOut.value,
                    "the park timed out: A's verdict landed before the rescan republished, so the generation guard never saw a moved generation")
            #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/A",
                    "a verdict from before the rescan must not land in the rescanned card")
        case .cancelledRescan:
            #expect(!parkTimedOut.value,
                    "the park timed out: A's verdict landed before the cancelled rescan bumped the epoch, so this control ran ungated and proves nothing")
            #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/Fresh",
                    "the cancelled rescan left the cards alone, so A's verdict is still about them")
        }
        // A no longer owns an entry after clearFiling, and otherwise its own defer releases it.
        #expect(manager.filingTryAnotherInFlight.isEmpty, "A's defer must release its own entry")
    }

    /// `filingScanFolder` labels what's ON SCREEN, so it publishes with the results — a cancelled
    /// rescan of a different folder must not relabel the previous results.
    @MainActor
    @Test func filingScanFolderLabelsResultsNotTheInFlightScan() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
        let downloads = root.appendingPathComponent("Downloads")
        let rootB = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: rootB) }

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(manager.filingScanFolder == downloads.path, "a completed scan labels its results")
        let suggestionsBefore = manager.filingSuggestions.map(\.id)

        // A rescan of a DIFFERENT folder, cancelled before it publishes.
        manager.startFindFilingSuggestions(folder: rootB.appendingPathComponent("Downloads"), providerRoot: rootB)
        manager.cancelFindFilingSuggestions()
        await manager.filingScanTask?.value

        #expect(manager.filingScanFolder == downloads.path, "the label must still match the on-screen results")
        #expect(manager.filingSuggestions.map(\.id) == suggestionsBefore)
    }
}

