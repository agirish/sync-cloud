import Testing
import Foundation
import Events
@testable import Sync

/// Manager-level coverage for Filing: the end-to-end scan (real folders) and the apply path
/// (real move, creating new folders, undoable).
/// A tiny thread-safe flag for asserting whether an injected closure ran, and for releasing a
/// closure parked in another isolation domain. Lock-backed: the plain `var` this used to be was
/// written from a test and read from an injected closure with no synchronization at all — a data
/// race TSan flags, and one whose torn read would hang a parked spin forever.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// A tiny thread-safe call counter for injected closures, lock-backed for the same reason as
/// ``Flag``: it is written from a classifier closure in another isolation domain and read from
/// the test's spins.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    /// Increments and returns the new value — atomic, so concurrent callers each see a distinct
    /// ordinal (1 for the first call, 2 for the second, …).
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

@Suite struct FileSyncManagerFilingTests {

    private func write(_ url: URL, bytes: Int = 5000, fill: UInt8 = 0x41) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func findFilingSuggestionsFindsHomesInYourFolders() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)   // existing Vehicles folder
        try write(root.appendingPathComponent("Downloads/Tesla Auto Policy.pdf"))
        try write(root.appendingPathComponent("Downloads/zxqw9.bin"))

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(manager.hasSuggestedFiling)
        let tesla = manager.filingSuggestions.first { $0.fileName.hasPrefix("Tesla") }
        #expect(tesla?.best?.path.hasSuffix("Documents/Vehicles/Tesla/Insurance") == true)
        #expect(tesla?.best?.newSegments == ["Tesla", "Insurance"])
        // The unrecognized file appears but with no confident home.
        let junk = manager.filingSuggestions.first { $0.fileName == "zxqw9.bin" }
        #expect(junk?.hasConfidentHome == false)
    }

    @MainActor
    @Test func applyFilingMovesFileAndCreatesNewFolders() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(srcPath)

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
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
        let junkPath = root.appendingPathComponent("Downloads/zxqw9.bin")
        try write(junkPath)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(manager.filingSuggestions.count == 2)

        await manager.applyRecommendedFiling(manager.batchEligibleFilingSuggestions)

        // The Tesla file moved; the unrecognized one stays put and stays in the list.
        #expect(FileManager.default.fileExists(atPath: junkPath.path))
        #expect(manager.filingSuggestions.count == 1)
        #expect(manager.filingSuggestions.first?.fileName == "zxqw9.bin")
    }

    @MainActor
    @Test func contentExtractorUpgradesFilesWithNoHomeFromTheName() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/scan0012.pdf"))

        let manager = FileSyncManager()
        // Simulate on-device extraction finding the entities inside the uninformatively-named scan.
        manager.filingContentExtractor = { path in
            path.hasSuffix("scan0012.pdf") ? ["tesla", "policy", "geico"] : []
        }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let scan = manager.filingSuggestions.first { $0.fileName == "scan0012.pdf" }
        #expect(scan?.best?.path.hasSuffix("Documents/Vehicles/Tesla/Insurance") == true)
        #expect(scan?.best?.reasons.first?.contains("read from the file") == true)
    }

    @MainActor
    @Test func applyingToTheFilesOwnFolderIsANoOpNotARename() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcPath = root.appendingPathComponent("Downloads/report.pdf")
        try write(srcPath)

        let manager = FileSyncManager()
        let s = FilingSuggestion(filePath: srcPath.path, fileName: "report.pdf", size: 5000,
                                 modificationDate: nil, candidates: [])
        manager.filingSuggestions = [s]
        let dest = FilingDestination(path: root.appendingPathComponent("Downloads").path,
                                     confidence: .high, reasons: [], newSegments: [])

        let ok = await manager.applyFilingSuggestion(s, to: dest)

        #expect(ok == .notNeeded)   // filing into its own folder is a no-op success, not a move
        #expect(FileManager.default.fileExists(atPath: srcPath.path))                                   // unchanged
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/report 2.pdf").path))
        #expect(manager.filingSuggestions.isEmpty)                                                      // dropped from list
    }

    /// The same no-op, reached through a destination whose CASE differs from the folder on disk.
    ///
    /// Automation destination templates are matched case-insensitively by design, so a rule
    /// destination hand-typed as "downloads" naming the on-disk "Downloads" is expected input. The
    /// three "is this the file's own folder?" tests compared paths exactly, so on the default
    /// case-insensitive volume the destination read as a DIFFERENT folder: the move went ahead,
    /// `fileExists` found the file itself (case collapsed on disk), the unique-name helper stepped
    /// around it, and the file was renamed in place to "report 2.pdf" under a banner reporting a
    /// successful filing.
    @MainActor
    @Test func applyingToACaseVariantOfTheFilesOwnFolderIsAlsoANoOp() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcPath = root.appendingPathComponent("Downloads/report.pdf")
        try write(srcPath)

        // Skip where the answer would legitimately differ: on a case-SENSITIVE volume these really
        // are two folders, and filing into the second is a real move, not a no-op.
        guard !FileSyncManager.volumeSupportsCaseSensitiveNames(for: root) else { return }

        let manager = FileSyncManager()
        let s = FilingSuggestion(filePath: srcPath.path, fileName: "report.pdf", size: 5000,
                                 modificationDate: nil, candidates: [])
        manager.filingSuggestions = [s]
        let dest = FilingDestination(path: root.appendingPathComponent("downloads").path,
                                     confidence: .high, reasons: [], newSegments: [])

        let ok = await manager.applyFilingSuggestion(s, to: dest)

        #expect(ok == .notNeeded)
        #expect(FileManager.default.fileExists(atPath: srcPath.path))
        // The rename this guard exists to prevent.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/report 2.pdf").path))
        #expect(manager.filingSuggestions.isEmpty)
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
        // And the case-sensitive volume keeps its honest answer: there, the two really do differ,
        // so the candidate stands — which is also what proves the assertion above measures the
        // filter rather than the rule simply never producing this candidate.
        let sensitive = FilingEngine.suggest(
            looseFiles: [file], taxonomy: taxonomy, providerRoot: "/root",
            automations: [rule], options: FilingOptions(caseSensitiveVolume: true))
        #expect(offersTheParent(sensitive) == true)
    }

    @MainActor
    @Test func batchFilingIsASingleUndo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let tesla = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        let toyota = root.appendingPathComponent("Downloads/Toyota Registration.pdf")
        try write(tesla); try write(toyota)

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(manager.filingSuggestions.filter { $0.isBatchEligible }.count == 2)

        await manager.applyRecommendedFiling(manager.batchEligibleFilingSuggestions)
        #expect(!FileManager.default.fileExists(atPath: tesla.path))
        #expect(!FileManager.default.fileExists(atPath: toyota.path))

        // A single ⌘Z reverts the whole batch.
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
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/scan0012.pdf")
        try write(srcPath)

        let manager = FileSyncManager()
        manager.filingContentExtractor = { $0.hasSuffix("scan0012.pdf") ? ["tesla", "policy"] : [] }
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let scan = manager.filingSuggestions.first { $0.fileName == "scan0012.pdf" }
        #expect(scan?.hasConfidentHome == true)     // content gave it a home
        #expect(scan?.isBatchEligible == false)     // but content-derived → not batch-eligible

        await manager.applyRecommendedFiling(manager.batchEligibleFilingSuggestions)
        #expect(FileManager.default.fileExists(atPath: srcPath.path))   // the batch did NOT move it
    }

    @MainActor
    @Test func readContentsToggleOffSkipsExtraction() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/scan0012.pdf"))

        let manager = FileSyncManager()
        let suite = "FilingToggle-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
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
        // Session rejections are keyed by file path; a provider switch invalidates them (another
        // provider can legitimately host a same-named path), so clearFiling must drop them.
        #expect(manager.filingSessionRejections.isEmpty)
    }

    /// "Try another" on a file whose name has no salient tokens ("IMG 0007" — exactly the files
    /// the content/AI pipeline exists for) can't persist a token-keyed rejection, but the click
    /// must still take effect: the rejected folder never comes back for that file. It used to
    /// re-install the identical candidate list forever.
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

    /// Points the manager's rule store at a throwaway suite so tests never touch standard defaults.
    @MainActor private func manager(withRuleSuite suite: String) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingRuleDefaults = UserDefaults(suiteName: suite)!
        return m
    }

    @MainActor
    @Test func applyingWithRememberPersistsAReusableRule() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Archive/Tesla/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(srcPath)

        let suite = "FilingRules-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }

        // File it into Archive/Tesla and ask Filing to remember the correction.
        let s = FilingSuggestion(filePath: srcPath.path, fileName: "Tesla Policy.pdf", size: 5000,
                                 modificationDate: nil, candidates: [])
        manager.filingSuggestions = [s]
        let dest = FilingDestination(path: root.appendingPathComponent("Archive/Tesla").path,
                                     confidence: .high, reasons: [], newSegments: [])
        _ = await manager.applyFilingSuggestion(s, to: dest, remember: true)

        // An automation keyed on "tesla" now exists (nothing is written to the legacy F3 store)…
        #expect(manager.automationRules.count == 1)
        #expect(manager.automationRules.first?.conditions == [.mentionsAll(["tesla"])])
        #expect(manager.filingRules.isEmpty)

        // …and a fresh scan of another Tesla file files it into that same remembered folder,
        // high-confidence & batch-eligible, carrying the "remembered" flag.
        try write(root.appendingPathComponent("Downloads/tesla renewal 2025.pdf"))
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let renewal = manager.filingSuggestions.first { $0.fileName.hasPrefix("tesla renewal") }
        #expect(renewal?.best?.path == root.appendingPathComponent("Archive/Tesla").path)
        #expect(renewal?.best?.remembered == true)
        #expect(renewal?.isBatchEligible == true)
    }

    @MainActor
    @Test func rulesAreScopedToTheProviderTheyPointInto() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/tesla thing.pdf"))

        let suite = "FilingRules-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }
        // A rule whose destination lives in a DIFFERENT provider's tree must never fire here.
        manager.filingRules = [FilingRule(tokens: ["tesla"], destinationPath: "/SomeOtherProvider/Cars")]

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let s = manager.filingSuggestions.first { $0.fileName == "tesla thing.pdf" }
        #expect(!(s?.candidates.contains { $0.remembered } ?? false))
    }

    @MainActor
    @Test func rememberingCreatesAMentionsAutomation() {
        let suite = "RememberAuto-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }

        // A learned rule stores the ABSOLUTE folder it filed into — the same provider scoping the
        // legacy remembered rules had, so it can never batch-file into another provider.
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

    /// Value-unchanged guard: `setAutomationRule` with the already-stored value must be a no-op —
    /// no re-persist, and (the observable pin) no duplicate "enabled/disabled" audit-log line. The
    /// card's Toggle only fires on a real flip today, but this is the public seam any future
    /// external mutator would call, and it must not double-log.
    @MainActor
    @Test func settingAnUnchangedEnabledStateDoesNotDoubleLog() async {
        let suite = "SetRuleNoOp-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }

        let rule = AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                                  destinationTemplate: "Cars/Tesla")
        manager.upsertAutomationRule(rule)

        // Awaiting a fresh log task first guarantees everything enqueued before it is visible.
        func logCount(_ message: String) async -> Int {
            await Logger.shared.debug("set-rule no-op flush marker").value
            return Logger.shared.entries.filter { $0.message == message }.count
        }
        let disabledLine = "Automation rule disabled: “Tesla”"
        let baseline = await logCount(disabledLine)

        // A real flip logs exactly once…
        manager.setAutomationRule(id: rule.id, enabled: false)
        #expect(manager.automationRules.first?.enabled == false)
        #expect(await logCount(disabledLine) == baseline + 1)

        // …and repeating the same value changes nothing and logs nothing.
        manager.setAutomationRule(id: rule.id, enabled: false)
        #expect(manager.automationRules.first?.enabled == false)
        #expect(await logCount(disabledLine) == baseline + 1)
    }

    @MainActor
    @Test func legacyRulesMigrateIntoAutomations() {
        let suite = "RuleMigration-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }

        manager.filingRules = [
            FilingRule(tokens: ["tesla"], destinationPath: "/p/Cars/Tesla"),
            FilingRule(tokens: ["geico"], destinationPath: "/p/Insurance/Geico", enabled: false),
        ]

        manager.migrateFilingRulesToAutomations()

        let migrated = manager.automationRules
        #expect(migrated.count == 2)
        let tesla = migrated.first { $0.conditions == [.mentionsAll(["tesla"])] }
        // The destination stays ABSOLUTE — the exact provider scoping the legacy rule had.
        #expect(tesla?.destinationTemplate == "/p/Cars/Tesla")
        #expect(tesla?.enabled == true)
        #expect(tesla?.name == "Tesla")
        // Disabled state survives the migration.
        #expect(migrated.first { $0.conditions == [.mentionsAll(["geico"])] }?.enabled == false)
        // The legacy store is left in place as a backup…
        #expect(manager.filingRules.count == 2)
        // …and the migration is one-shot: re-running adds nothing.
        manager.migrateFilingRulesToAutomations()
        #expect(manager.automationRules.count == 2)
    }

    /// Once the migration flag is set, the legacy store is truly unconsulted: a legacy rule whose
    /// destination DIVERGES from its migrated automation must not add a second candidate.
    @MainActor
    @Test func legacyStoreIsUnconsultedAfterMigration() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Archive/Tesla/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Legacy/Tesla/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/tesla renewal.pdf"))

        let suite = "PostFlag-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }
        manager.filingRules = [FilingRule(tokens: ["tesla"],
                                          destinationPath: root.appendingPathComponent("Legacy/Tesla").path)]
        manager.migrateFilingRulesToAutomations()
        // Re-point the automation somewhere else; the legacy store still holds Legacy/Tesla.
        var rule = manager.automationRules[0]
        rule.destinationTemplate = root.appendingPathComponent("Archive/Tesla").path
        manager.upsertAutomationRule(rule)

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let s = manager.filingSuggestions.first { $0.fileName.hasPrefix("tesla") }
        #expect(s?.best?.path == root.appendingPathComponent("Archive/Tesla").path)
        // Legacy/Tesla may still surface as a plain taxonomy candidate (the folder exists and
        // shares a token) — what must NOT happen is the legacy RULE steering it as remembered.
        #expect(!(s?.candidates.contains { $0.remembered && $0.path.hasSuffix("Legacy/Tesla") } ?? true))
    }

    /// The provable-preservation pin for the unification: a legacy remembered rule and its migrated
    /// automation steer the SAME suggestion — same destination, remembered flag, high confidence,
    /// and batch eligibility — so teaching survives the migration without behavior drift.
    @MainActor
    @Test func migratedRuleSteersLikeTheLegacyRule() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Archive/Tesla/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/tesla renewal 2025.pdf"))

        // Pass 1 — the legacy F3 rule steers (pre-migration path).
        let legacySuite = "SteerLegacy-\(UUID().uuidString)"
        let legacyManager = manager(withRuleSuite: legacySuite)
        defer { wipeDefaultsSuite(legacySuite) }
        legacyManager.filingRules = [FilingRule(tokens: ["tesla"],
                                                destinationPath: root.appendingPathComponent("Archive/Tesla").path)]
        await legacyManager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let fromLegacy = legacyManager.filingSuggestions.first { $0.fileName.hasPrefix("tesla renewal") }

        // Pass 2 — the same rule after migration steers via the automation path.
        let migratedSuite = "SteerMigrated-\(UUID().uuidString)"
        let migratedManager = manager(withRuleSuite: migratedSuite)
        defer { wipeDefaultsSuite(migratedSuite) }
        migratedManager.filingRules = [FilingRule(tokens: ["tesla"],
                                                  destinationPath: root.appendingPathComponent("Archive/Tesla").path)]
        migratedManager.migrateFilingRulesToAutomations()
        await migratedManager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let fromMigrated = migratedManager.filingSuggestions.first { $0.fileName.hasPrefix("tesla renewal") }

        #expect(fromLegacy?.best?.path == root.appendingPathComponent("Archive/Tesla").path)
        #expect(fromMigrated?.best?.path == fromLegacy?.best?.path)
        #expect(fromMigrated?.best?.remembered == true)
        #expect(fromMigrated?.best?.confidence == fromLegacy?.best?.confidence)
        #expect(fromMigrated?.isBatchEligible == fromLegacy?.isBatchEligible)
        #expect(fromMigrated?.isBatchEligible == true)
    }

    /// An automation with an absolute destination pointing into a DIFFERENT provider must never
    /// steer this provider's scan — the same scoping the legacy rules had.
    @MainActor
    @Test func automationsAreScopedToTheProviderTheyPointInto() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/tesla thing.pdf"))

        let suite = "AutoScope-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }
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

    /// A rule whose match rests only on the file's CONTENT is capped to medium and kept out of the
    /// blind batch — the same cap every content-derived signal gets.
    @Test func contentOnlyRuleMatchIsMediumAndNotBatchEligible() {
        let file = FileNode(id: "/p/Inbox/scan0042.pdf", name: "scan0042.pdf", isDirectory: false,
                            children: nil, modificationDate: Date(), fileSize: 5000)
        let rule = AutomationRule(name: "Geico", conditions: [.mentionsAll(["geico"])],
                                  destinationTemplate: "/p/Insurance/Geico")

        let steered = FilingEngine.suggest(looseFiles: [file], taxonomy: [], providerRoot: "/p",
                                           contentTokens: [file.id: ["geico", "policy"]],
                                           automations: [rule])
        #expect(steered.first?.best?.path == "/p/Insurance/Geico")
        #expect(steered.first?.best?.confidence == .medium)
        #expect(steered.first?.best?.fromContent == true)
        #expect(steered.first?.isBatchEligible == false)

        // Legacy parity for the learned shape: a MIXED match (one trigger word in the name) counts
        // as name-derived — high confidence and batch-eligible, exactly as F3 behaved.
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
        try write(root.appendingPathComponent("Inbox/scan0001.pdf"))
        try write(root.appendingPathComponent("Inbox/tesla-note.pdf"))

        let suite = "SnippetParity-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)
        defer { wipeDefaultsSuite(suite) }
        manager.upsertAutomationRule(AutomationRule(name: "Lease", conditions: [.mentionsAll(["lease"])],
                                                    destinationTemplate: root.appendingPathComponent("Home/Lease").path))

        // "lease" is a generic word the sparse entity extractor would never surface — only the
        // raw text knows it. The name-matched file must NOT be read (its rule outcome can't flip).
        let read = ReadPaths()
        manager.filingSnippetExtractor = { path in
            await read.record(path)
            return path.hasSuffix("scan0001.pdf") ? "lease agreement for unit 4" : nil
        }
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"), providerRoot: root)

        let steered = manager.filingSuggestions.first { $0.fileName == "scan0001.pdf" }
        #expect(steered?.best?.path == root.appendingPathComponent("Home/Lease").path)
        #expect(steered?.best?.remembered == true)
        #expect(steered?.best?.fromContent == true)
        let paths = await read.paths
        #expect(paths.contains { $0.hasSuffix("scan0001.pdf") })
    }

    @MainActor
    @Test func rejectionsPersistMatchAndClear() {
        let suite = "FilingRej-\(UUID().uuidString)"
        let manager = manager(withRuleSuite: suite)   // rejections share filingRuleDefaults
        defer { wipeDefaultsSuite(suite) }

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
        // Phase 3 must apply the same ignoredNames/minFileSize filters the suggestion engine
        // applies: an unfiltered candidate list put ".DS_Store" into the PAID classifier
        // request (its name in the prompt, its slot against the 150-file cloud / 25-file
        // on-device cap), and any verdict for it was then silently discarded because no
        // suggestion exists for filtered names. Junk-heavy folders pushed real files past
        // the cap, losing their classification outright.
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Stuff/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/.DS_Store"), bytes: 500)
        try write(root.appendingPathComponent("Downloads/mystery-scan-0042.pdf"))

        final class Names: @unchecked Sendable { var value: [String] = [] }
        let seen = Names()
        let manager = FileSyncManager()
        manager.filingClassifier = { _, files in
            seen.value = files.map(\.fileName)
            return [:]
        }
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(seen.value.contains("mystery-scan-0042.pdf"))   // real files still classified
        #expect(!seen.value.contains(".DS_Store"))              // junk never reaches the model
    }

    @MainActor
    @Test func classifierVerdictDrivesTheSuggestion() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Family/Divit/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Physician's Report - Divit.pdf"))

        let manager = FileSyncManager()
        // A stand-in for the on-device model: it "reasons" Divit → Family/Divit.
        manager.filingClassifier = { taxonomy, files in
            #expect(taxonomy.contains("Documents/Family/Divit"))     // handed the real taxonomy
            var out: [String: FilingVerdict] = [:]
            for f in files where f.fileName.contains("Divit") {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Divit",
                                                confidence: .high, reason: "Divit’s medical record")
            }
            return out
        }

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let s = manager.filingSuggestions.first { $0.fileName.contains("Divit") }
        #expect(s?.best?.path == root.appendingPathComponent("Documents/Family/Divit").path)
        #expect(s?.best?.fromAI == true)
        #expect(s?.best?.reasons.first == "Divit’s medical record")
    }

    @MainActor
    @Test func aiToggleOffSkipsTheClassifier() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/mystery.pdf"))

        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
        manager.filingContentDefaults.set(false, forKey: FileSyncManager.usesAIDefaultsKey)
        // A classifier that WOULD give a home — proving it isn't consulted when AI is off.
        let consulted = Flag()
        manager.filingClassifier = { _, files in
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
        let manager = FileSyncManager()
        let consulted = Flag()
        manager.filingClassifier = { _, _ in consulted.value = true; return [:] }
        manager.filingLastProviderRoot = "/other"          // stale: another provider's scan
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0008.HEIC", fileName: "IMG_0008.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        #expect(consulted.value == false, "must not resolve against the wrong provider's taxonomy")
        #expect(manager.filingSuggestions.first?.candidates.isEmpty == true, "falls back to Choose a folder…")
    }

    @MainActor
    @Test func tryAnotherFolderReasksBackendWhenCacheMatchesProvider() async throws {
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
        manager.filingClassifier = { _, files in
            Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"              // cache belongs to this provider
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0009.HEIC", fileName: "IMG_0009.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        let best = manager.filingSuggestions.first?.best
        #expect(best?.path == "/p/Docs/Fresh")
        #expect(best?.fromAI == true)
        #expect(best?.newSegments == ["Fresh"])
    }

    /// The cached existing/taxonomy folder sets used to be read on BOTH sides of the classifier
    /// await; a Filing scan of another provider (or `clearFiling()`) during the round-trip swaps
    /// or empties them, and labeling the verdict against the swapped set marks every segment new
    /// — so the "Creates N new folders." confirmation lies. The verdict must be labeled against
    /// the sets snapshotted at the same pre-await point where the provider root was validated.
    @MainActor
    @Test func tryAnotherFolderLabelsVerdictAgainstPreAwaitSnapshot() async throws {
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        manager.filingRuleDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
        manager.filingClassifier = { _, files in
            // Another provider's scan lands while the classifier is out: it overwrites every
            // cached set (clearFiling would empty them — same failure shape).
            await MainActor.run {
                manager.filingLastProviderRoot = "/other"
                manager.filingLastTaxonomyFolders = ["Zebra"]
                manager.filingLastExistingFolders = ["Zebra"]
            }
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        // "Docs/Fresh" already exists (captured beyond the classifier cap) — nothing to create.
        manager.filingLastExistingFolders = ["Docs", "Docs/Fresh"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0010.HEIC", fileName: "IMG_0010.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        let best = manager.filingSuggestions.first?.best
        #expect(best?.path == "/p/Docs/Fresh")
        #expect(best?.newSegments == [], "labeled against the snapshot: Docs/Fresh existed when the re-ask was issued")
    }

    /// The other arm of the same snapshot rule. When the full existing-folder set was never
    /// captured, the labeling falls back to the (capped) taxonomy list — and THAT list must be
    /// the pre-await snapshot too. The sibling test above always has a non-empty
    /// `filingLastExistingFolders`, so it never reaches this branch: reverting the fallback to a
    /// live `filingLastTaxonomyFolders` read leaves it green while the confirmation lies again.
    @MainActor
    @Test func tryAnotherFolderFallsBackToTheSnapshottedTaxonomyList() async throws {
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        manager.filingRuleDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
        manager.filingClassifier = { _, files in
            // Another provider's scan lands mid-round-trip and swaps the taxonomy list.
            await MainActor.run {
                manager.filingLastProviderRoot = "/other"
                manager.filingLastTaxonomyFolders = ["Zebra"]
            }
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"
        // Both folders already exist, and only the taxonomy list knows it — the full set was
        // never captured, which is exactly what puts the fallback arm in play.
        manager.filingLastTaxonomyFolders = ["Docs", "Docs/Fresh"]
        manager.filingLastExistingFolders = []
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0012.HEIC", fileName: "IMG_0012.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        await manager.tryAnotherFolder(for: s)

        let best = manager.filingSuggestions.first?.best
        #expect(best?.path == "/p/Docs/Fresh")
        #expect(best?.newSegments == [],
                "the fallback must use the taxonomy list snapshotted pre-await, not the swapped one")
    }

    /// Each "Try another" click fires its own unstructured Task; without a guard two rapid
    /// clicks run two classifier round-trips for the same card and whichever RETURNS last wins.
    /// A second call while the first is parked at the classifier must be a no-op.
    @MainActor
    @Test func tryAnotherFolderIgnoresReentrantCallForSameSuggestion() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
            func increment() { lock.lock(); count += 1; lock.unlock() }
        }
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        manager.filingRuleDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }

        let calls = Counter()
        let released = Flag()
        manager.filingClassifier = { _, files in
            // Only the FIRST round-trip parks: a second one (the bug this test pins) returns
            // immediately, so a regressed build fails the call-count check below instead of
            // deadlocking the suite waiting for a release that can never come.
            if calls.value == 0 {
                calls.increment()
                // Park until the test releases it — with a deadline, so a mis-wired test fails
                // on its assertions instead of spinning this suite until the CI job times out.
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !released.value, ContinuousClock.now < deadline { await Task.yield() }
            } else {
                calls.increment()
            }
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0011.HEIC", fileName: "IMG_0011.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        let first = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        // Let the first call reach the classifier and park there (bounded, same reason).
        let arrival = ContinuousClock.now.advanced(by: .seconds(10))
        while calls.value == 0, ContinuousClock.now < arrival { await Task.yield() }
        #expect(calls.value == 1, "the first re-ask must reach the classifier")

        await manager.tryAnotherFolder(for: s)   // the second rapid click
        #expect(calls.value == 1, "a re-entrant Try another for the same card must not start a second round-trip")

        released.value = true
        await first.value
        #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/Fresh")
        #expect(manager.filingTryAnotherInFlight.isEmpty, "the completed re-ask must release its id")

        // The guard must be a latch that OPENS, not one that shuts for good: a THIRD click,
        // after the first round-trip returned, has to reach the classifier again. Without this
        // call the suite stays green with `tryAnotherFolder`'s releasing `defer` deleted —
        // shipping a "Try another" that works exactly once per card.
        let refreshed = try #require(manager.filingSuggestions.first)
        await manager.tryAnotherFolder(for: refreshed)
        #expect(calls.value == 2, "once the first re-ask returned, the next click must re-ask again")
    }

    /// `tryAnotherFolder` releases its in-flight id in a `defer` — but only if it returns, and
    /// `FilingClassifier` has no timeout. A round-trip that never comes back would latch the id
    /// forever, making every later "Try another" for that card a silent no-op with no way out.
    /// `clearFiling()` (switch providers, rescan) is that way out, so it must clear the set —
    /// it resets every other piece of filing state on the same line.
    @MainActor
    @Test func clearFilingReleasesStuckTryAnotherIds() async throws {
        let manager = FileSyncManager()
        manager.filingTryAnotherInFlight = ["/p/Downloads/Stuck.pdf": UUID()]

        manager.clearFiling()

        #expect(manager.filingTryAnotherInFlight.isEmpty,
                "a classifier round-trip that never returns must not latch the card forever")
    }

    /// The recovery hatch must not re-arm the race it recovers from. `filingTryAnotherInFlight`
    /// is keyed by suggestion id — the file's ABSOLUTE PATH, stable across scans and sessions —
    /// so after round-trip A wedges, `clearFiling()` releases /X, a rescan recreates the card
    /// under the SAME id, and a new click starts round-trip B, A's unconditional releasing
    /// `defer` strips B's still-out guard: a third click then runs concurrently with B and
    /// "whichever returned last wins" is back. A stale invocation may release only its OWN entry.
    @MainActor
    @Test func staleTryAnotherDeferMustNotReleaseTheNewRoundTripsGuard() async throws {
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        manager.filingRuleDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }

        let calls = CallCounter()
        let releaseA = Flag()
        let releaseB = Flag()
        manager.filingClassifier = { _, files in
            // Round-trip A parks on its own gate, B on its own; anything later (the bug this
            // test pins) returns immediately so a regressed build fails the call-count check
            // below instead of deadlocking the suite. Bounded parks, same reason.
            switch calls.next() {
            case 1:
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !releaseA.value, ContinuousClock.now < deadline { await Task.yield() }
            case 2:
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !releaseB.value, ContinuousClock.now < deadline { await Task.yield() }
            default: break
            }
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0020.HEIC", fileName: "IMG_0020.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        // Round-trip A reaches the classifier and parks there (wedged — no timeout exists).
        let a = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        let arrivalA = ContinuousClock.now.advanced(by: .seconds(10))
        while calls.value == 0, ContinuousClock.now < arrivalA { await Task.yield() }
        #expect(calls.value == 1, "round-trip A must reach the classifier")

        // The user switches providers away and back (clearFiling releases /X), and a rescan
        // recreates the card under the same id.
        manager.clearFiling()
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        manager.filingSuggestions = [s]

        // Round-trip B starts for the recreated card and parks in turn.
        let b = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        let arrivalB = ContinuousClock.now.advanced(by: .seconds(10))
        while calls.value < 2, ContinuousClock.now < arrivalB { await Task.yield() }
        #expect(calls.value == 2, "round-trip B must reach the classifier")
        #expect(!manager.filingTryAnotherInFlight.isEmpty, "B's re-ask is out, so its guard is armed")

        // A finally returns. Its defer is stale — it must NOT release B's guard.
        releaseA.value = true
        await a.value
        #expect(!manager.filingTryAnotherInFlight.isEmpty,
                "A's stale defer released B's still-out guard — the ownership check is gone")

        // And with B still out, another click must be refused, not start a third round-trip.
        let recreated = try #require(manager.filingSuggestions.first)
        await manager.tryAnotherFolder(for: recreated)
        #expect(calls.value == 2,
                "a click while B is still out must be refused; a third concurrent round-trip is the raced bug")

        // B returns: its own defer releases its own entry, and its verdict lands as usual.
        releaseB.value = true
        await b.value
        #expect(manager.filingTryAnotherInFlight.isEmpty, "B's completed re-ask must release its own entry")
        #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/Fresh",
                "the CURRENT round-trip's verdict still lands")
    }

    /// The other half of the same hole: A's late RESULT. Its verdict was computed against the
    /// pre-clear taxonomy and rejections, but `replaceFilingSuggestion` keys on the suggestion id
    /// — the stable file path — so after clearFiling + rescan recreate the card, A's stale write
    /// lands in the NEW session's card. A verdict from an invocation that no longer owns its
    /// in-flight entry must be dropped.
    @MainActor
    @Test func staleTryAnotherResultMustNotOverwriteTheRecreatedCard() async throws {
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        manager.filingRuleDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }

        let calls = CallCounter()
        let releaseA = Flag()
        manager.filingClassifier = { _, files in
            if calls.next() == 1 {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !releaseA.value, ContinuousClock.now < deadline { await Task.yield() }
            }
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0021.HEIC", fileName: "IMG_0021.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        let a = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        let arrival = ContinuousClock.now.advanced(by: .seconds(10))
        while calls.value == 0, ContinuousClock.now < arrival { await Task.yield() }
        #expect(calls.value == 1, "round-trip A must reach the classifier")

        // Provider switch releases A's entry; the rescan recreates the card — same id, fresh
        // session state.
        manager.clearFiling()
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        manager.filingSuggestions = [s]

        releaseA.value = true
        await a.value
        #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/A",
                "a verdict computed against the pre-clear session must not land in the recreated card")
    }

    /// A Filing rescan is the third way the state moves on mid-round-trip: it assigns
    /// `filingSuggestions` directly WITHOUT touching `filingTryAnotherInFlight`, so the stale
    /// invocation still owns its entry and an ownership check alone lets its write through. The
    /// scan lifecycle's epoch is what a rescan does bump — the same currency check the status
    /// line already uses must gate the result write.
    @MainActor
    @Test func tryAnotherResultIsDroppedWhenARescanSupersedesItMidRoundTrip() async throws {
        let manager = FileSyncManager()
        let suite = "FilingAI-\(UUID().uuidString)"
        manager.filingContentDefaults = UserDefaults(suiteName: suite)!
        manager.filingRuleDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }

        let calls = CallCounter()
        let releaseA = Flag()
        manager.filingClassifier = { _, files in
            if calls.next() == 1 {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !releaseA.value, ContinuousClock.now < deadline { await Task.yield() }
            }
            return Dictionary(uniqueKeysWithValues: files.map { ($0.filePath,
                FilingVerdict(relativePath: "Docs/Fresh", confidence: .medium, reason: "ai")) })
        }
        manager.filingLastProviderRoot = "/p"
        manager.filingLastTaxonomyFolders = ["Docs"]
        let d1 = FilingDestination(path: "/p/Docs/A", confidence: .medium, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/p/Downloads/IMG_0022.HEIC", fileName: "IMG_0022.HEIC",
                                 size: 1, modificationDate: nil, candidates: [d1], providerRoot: "/p")
        manager.filingSuggestions = [s]

        let a = Task { @MainActor in await manager.tryAnotherFolder(for: s) }
        let arrival = ContinuousClock.now.advanced(by: .seconds(10))
        while calls.value == 0, ContinuousClock.now < arrival { await Task.yield() }
        #expect(calls.value == 1, "round-trip A must reach the classifier")

        // A rescan runs to completion while A is parked (real state machine: begin bumps the
        // epoch, end bumps it again) and republishes the card — same id, new session state.
        manager.beginScan(\.filingScanLifecycle, status: "Rescanning…")
        manager.endScan(\.filingScanLifecycle)
        manager.filingSuggestions = [s]

        releaseA.value = true
        await a.value
        #expect(manager.filingSuggestions.first?.best?.path == "/p/Docs/A",
                "a verdict from before the rescan must not land in the rescanned card")
        #expect(manager.filingTryAnotherInFlight.isEmpty,
                "no clearFiling ran, so A still owned its entry and its defer must release it")
    }

    /// `filingScanFolder` labels what's ON SCREEN, so it publishes with the results — a cancelled
    /// rescan of a different folder must not relabel the previous results.
    @MainActor
    @Test func filingScanFolderLabelsResultsNotTheInFlightScan() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
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


/// Records which paths a stubbed snippet extractor was asked to read, across Sendable closures.
private actor ReadPaths {
    private(set) var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}
