import Testing
import Foundation
import Events
@testable import Sync

/// Rename folded into Organize: the Filing scan now reports cloud-hostile names on the pass it was
/// already making, instead of a separate place you had to remember to visit.
///
/// The claim being tested is a *coverage* claim, not a plumbing one. The standalone Rename scan
/// walked the whole provider; the Filing scan walks the loose folder at depth 1 AND the whole
/// provider for its taxonomy. If the fold quietly attached the detector to the shallow walk, the
/// finding would only ever see the inbox — it would still work, still show a count, and silently
/// miss every risky name in the rest of the provider.
@Suite struct FilingNameFindingTests {

    private func write(_ url: URL, bytes: Int = 500) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @MainActor
    @Test func theFilingScanReportsRiskyNamesFromTheWholeProviderNotJustTheInbox() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingNames")
        defer { try? FileManager.default.removeItem(at: root) }
        // Names that END in a space — the hazard, and one macOS will happily create. One sits in
        // the scanned inbox, one three levels away. A depth-1 detector finds only the first, which
        // is the regression this exists to catch.
        try write(root.appendingPathComponent("Downloads/inbox tail "))
        try write(root.appendingPathComponent("Documents/Archive/deep tail "))
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                            providerRoot: root, nameProvider: .oneDrive)

        let flagged = Set(manager.riskyNames.map(\.currentName))
        #expect(flagged.contains("inbox tail "))
        #expect(flagged.contains("deep tail "), "the finding must cover the whole provider, as the standalone scan did")
    }

    @MainActor
    @Test func theFindingIsEmptyWhenEveryNameIsSafe() async throws {
        // The chip's whole argument is that it is ABSENT on the common day. An empty finding has
        // to actually come back empty rather than, say, flagging every file with an extension.
        let root = try makeCanonicalTempRoot(prefix: "FilingNamesClean")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/Statement.pdf"))
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                            providerRoot: root, nameProvider: .oneDrive)

        #expect(manager.riskyNames.isEmpty)
    }

    @MainActor
    @Test func aScanWithNoNameProviderLeavesTheFindingUntouched() async throws {
        // The CLI and the engine tests call the scan without a provider. That must not be read as
        // "no risky names" — it is "nobody asked", and clobbering a previous finding with an empty
        // list would make the chip vanish for a reason the user never triggered.
        let root = try makeCanonicalTempRoot(prefix: "FilingNamesOptOut")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/tail "))

        let manager = FileSyncManager()
        manager.riskyNames = [RiskyName(id: "/pre/existing", relativePath: "existing",
                                        currentName: "existing ", sanitizedName: "existing",
                                        reason: "seeded", isDirectory: false)]

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                            providerRoot: root)

        #expect(manager.riskyNames.count == 1)
        #expect(manager.riskyNames.first?.currentName == "existing ")
    }

    @MainActor
    @Test func theRulesetIsTheScannedProvidersNotWhicheverPaneIsFocusedLater() async throws {
        // "Fix all" sanitizes against `nameScanProvider`. If the fold forgot to record it, the fix
        // would be computed against whatever the previous scan happened to leave there — a
        // different provider's rules, silently producing a different name than the one shown.
        let root = try makeCanonicalTempRoot(prefix: "FilingNamesRuleset")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/a.pdf"))

        let manager = FileSyncManager()
        manager.nameScanProvider = .dropBox
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                            providerRoot: root, nameProvider: .oneDrive)

        #expect(manager.nameScanProvider == .oneDrive)
    }

    // MARK: The single-file door (the pane row's "Fix name…")

    @Test func theOneNodeCheckAgreesWithTheWholeTreeScan() {
        // Two doors onto one rule. If they ever disagree, a name the batch flags would offer no
        // per-row fix — or worse, a row would offer a fix the batch does not believe in.
        let hazards = ["trailing ", "colon:name.pdf", "a\u{200B}b.txt"]
        let safe = ["Statement.pdf", "Café.pdf", "folder"]

        for name in hazards {
            let one = NameNormalizer.risky(name: name, relativePath: name, absolutePath: "/x/\(name)",
                                           isDirectory: false, provider: .oneDrive)
            #expect(one != nil, "“\(name)” is a hazard the row menu must offer to fix")
        }
        for name in safe {
            let one = NameNormalizer.risky(name: name, relativePath: name, absolutePath: "/x/\(name)",
                                           isDirectory: false, provider: .oneDrive)
            #expect(one == nil, "“\(name)” is safe — offering a fix would rename it for nothing")
        }
    }

    @Test func theOneNodeCheckProposesTheSameNameTheBatchWould() {
        // The menu item's help text quotes `sanitizedName`, and the fix routes through the same
        // `normalizeNames` the batch uses — so the two must produce one answer, not two.
        let name = "Q3: report .pdf"
        let one = NameNormalizer.risky(name: name, relativePath: name, absolutePath: "/x/\(name)",
                                       isDirectory: false, provider: .oneDrive)
        let batch = NameNormalizer.evaluate(name: name, relativePath: name, absolutePath: "/x/\(name)",
                                            isDirectory: false, provider: .oneDrive)
        #expect(one?.sanitizedName == batch?.sanitizedName)
        #expect(one?.reason == batch?.reason)
    }
}
