import Foundation
import Testing
@testable import Sync

/// **Both paid paths run Claude's answer through the cross-person rule**, driven end to end: Try
/// Another clicked until the card is re-asked, and Refine. Claude answers another person's folder
/// and the card is read, with the refusal in the veto log.
///
/// `FilingTryAnotherVetoTests` tests the rule; these are its call sites. Each control here is the
/// same pass without the profile, where that answer lands, so the refusal is the rule's and not the
/// harness's.
@MainActor
@Suite struct FilingTryAnotherVetoDrivenTests {

    /// Two person folders whose names say nothing a keyword could match, a neutral one the free
    /// pass answers, and a document named for Daughter.
    private func fixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "TryAnotherVeto-\(name)")
        try writeBytes(root.appendingPathComponent("Visa/A/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Visa/B/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Archive/2026/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/Daughter passport.pdf"))
        return root
    }

    /// `Visa/A` is Son's, `Visa/B` Daughter's. Recorded for `root`, so the scan of it uses this
    /// survey: a profile of another tree is set aside for a by-name pass, which has no person axis.
    private func profile(of root: URL) -> FolderProfile {
        let entries = [
            FolderProfileEntry(path: "Visa/A", role: .destination, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0, axes: ["person": "Son"]),
            FolderProfileEntry(path: "Visa/B", role: .destination, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 3, subfolderCount: 0, axes: ["person": "Daughter"]),
        ]
        return FolderProfile(profileId: "t", root: root.path,
                             folders: Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
                             personTokens: ["daughter", "son"])
    }

    /// The free pass answers `Archive/2026`; asked again, Claude answers Son's `Visa/A`.
    private func manager(root: URL, withProfile: Bool, asked: @escaping @Sendable () -> Void) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingContentDefaults = ScratchDefaults("FilingTryAnotherVetoDriven-content")
        m.filingRuleDefaults = ScratchDefaults("FilingTryAnotherVetoDriven-rules")
        m.filingPersonVetoLog = PersonVetoLog(userDefaults: ScratchDefaults("FilingTryAnotherVetoDriven-vetoes"))
        if withProfile {
            m.filingFolderProfile = profile(of: root)
            m.filingPersonRegistry = FilingTryAnotherVetoTests.household
        }
        m.filingBackendIdentity = { tier in
            tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity
        }
        m.filingCloudSpendConfirmer = { _ in true }
        m.filingClassifier = { _, files, tier in
            if tier == .refine { asked() }
            let dest = tier == .refine ? "Visa/A" : "Archive/2026"
            return Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: dest, confidence: .high, reason: "test"))
            })
        }
        return m
    }

    /// The card's home after Try Another has been clicked until Claude was asked again.
    private func homeAfterTheReAsk(withProfile: Bool) async throws -> (asked: Int, home: String?, vetoes: Int, root: URL) {
        let root = try fixture(withProfile ? "veto" : "control")
        let asked = LockedBox(0)
        let m = manager(root: root, withProfile: withProfile, asked: { asked.withLock { $0 += 1 } })
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let first = try #require(m.filingSuggestions.first, "the scan made no card")
        #expect(first.best?.path == root.appendingPathComponent("Archive/2026").path,
                "the free pass did not answer the neutral folder — the click below re-asks about something else")
        for _ in 0..<6 where asked.withLock({ $0 }) == 0 {
            guard let card = m.filingSuggestions.first, card.best != nil else { break }
            await m.tryAnotherFolder(for: card)
        }
        return (asked.withLock { $0 }, m.filingSuggestions.first?.best?.path,
                m.filingPersonVetoLog?.count(namedPerson: "daughter") ?? 0, root)
    }

    /// The card's home after Refine.
    private func homeAfterRefine(withProfile: Bool) async throws -> (asked: Int, home: String?, vetoes: Int, root: URL) {
        let root = try fixture(withProfile ? "refine-veto" : "refine-control")
        let asked = LockedBox(0)
        let m = manager(root: root, withProfile: withProfile, asked: { asked.withLock { $0 += 1 } })
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        _ = try #require(m.filingSuggestions.first, "the scan made no card")
        _ = await m.refineFilingSuggestions(m.filingSuggestions)
        return (asked.withLock { $0 }, m.filingSuggestions.first?.best?.path,
                m.filingPersonVetoLog?.count(namedPerson: "daughter") ?? 0, root)
    }

    @Test func anotherPersonsFolderIsNotPutOnTheCard() async throws {
        let control = try await homeAfterTheReAsk(withProfile: false)
        defer { try? FileManager.default.removeItem(at: control.root) }
        #expect(control.asked == 1, "the control never re-asked Claude")
        #expect(control.home == control.root.appendingPathComponent("Visa/A").path,
                "without a profile the answer should land — the harness, not the rule, refused it")

        let vetoed = try await homeAfterTheReAsk(withProfile: true)
        defer { try? FileManager.default.removeItem(at: vetoed.root) }
        #expect(vetoed.asked == 1, "Try Another never re-asked Claude")
        #expect(vetoed.home == nil, "Son's folder was put on Daughter's document: \(vetoed.home ?? "")")
        #expect(vetoed.vetoes == 1, "the refusal was not recorded for the People section")
        #expect(control.vetoes == 0)
    }

    @Test func refineDoesNotPutAnotherPersonsFolderOnTheCard() async throws {
        let control = try await homeAfterRefine(withProfile: false)
        defer { try? FileManager.default.removeItem(at: control.root) }
        #expect(control.asked == 1, "the control never asked Claude")
        #expect(control.home == control.root.appendingPathComponent("Visa/A").path,
                "without a profile the answer should land — the harness, not the rule, refused it")

        let vetoed = try await homeAfterRefine(withProfile: true)
        defer { try? FileManager.default.removeItem(at: vetoed.root) }
        #expect(vetoed.asked == 1, "Refine never asked Claude")
        #expect(vetoed.home == vetoed.root.appendingPathComponent("Archive/2026").path,
                "Refine replaced the free home with Son's folder, or with nothing: \(vetoed.home ?? "nil")")
        #expect(vetoed.vetoes == 1, "the refusal was not recorded for the People section")
        #expect(control.vetoes == 0)
    }
}
