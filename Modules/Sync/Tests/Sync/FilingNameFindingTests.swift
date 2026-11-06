import Testing
import Foundation
import Events
@testable import Sync

/// The Filing scan reports cloud-hostile names on the pass it already makes. This guards coverage:
/// the scan walks the loose folder at depth 1 and the whole provider for its taxonomy, and a
/// detector attached to the shallow walk would still show a count while missing every risky name
/// outside the inbox.
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
        // Names ending in a space, which macOS will create: one in the scanned inbox, one three
        // levels away. A depth-1 detector finds only the first.
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
        // The chip should be absent on the common day, so a clean tree must give an empty finding.
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
        // The CLI and engine tests scan without a provider. That means "nobody asked", not "no
        // risky names", so the previous finding stays and the chip doesn't vanish.
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
    @Test func theProposedNameIsComputedWithTheScannedProvidersRules() async throws {
        // `sanitizedName` is computed during the scan and "Fix all" renames to that stored string,
        // so the proposed name is what to pin. A colon is legal on iCloud and illegal on OneDrive,
        // so the two rulesets must differ here.
        let root = try makeCanonicalTempRoot(prefix: "FilingNamesRuleset")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/Q3: report.pdf"))

        let strict = FileSyncManager()
        await strict.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                           providerRoot: root, nameProvider: .oneDrive)
        let flagged = strict.riskyNames.first { $0.currentName == "Q3: report.pdf" }
        #expect(flagged != nil, "OneDrive forbids a colon — this name must be flagged")
        #expect(flagged?.sanitizedName.contains(":") == false,
                "the fix carried on the row must already be free of the character its ruleset bans")

        let lenient = FileSyncManager()
        await lenient.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                            providerRoot: root, nameProvider: .iCloud)
        #expect(!lenient.riskyNames.contains { $0.currentName == "Q3: report.pdf" },
                "iCloud allows it — flagging it here would propose a rename nobody needs")
    }

    @MainActor
    @Test func aScanThatOptsOutOfTheNameCheckLeavesTheFindingAlone() async throws {
        // A caller that doesn't ask for the name check leaves the previous finding as it was. An
        // empty list would read as "nothing is wrong" and take the chip off screen.
        let root = try makeCanonicalTempRoot(prefix: "FilingNamesPairing")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/a.pdf"))

        let manager = FileSyncManager()
        // Stand in for a completed OneDrive scan's results.
        manager.riskyNames = [RiskyName(id: "/prev/tail ", relativePath: "tail ",
                                        currentName: "tail ", sanitizedName: "tail",
                                        reason: "a trailing space", isDirectory: false)]

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                            providerRoot: root)

        #expect(manager.riskyNames.count == 1)
    }

    @MainActor
    @Test func aCancelledDetectionDoesNotReplaceTheNamesOnScreen() async {
        // A cancelled scan publishes nothing: a partial or empty result would change the chip's
        // count on the strength of an abandoned scan. Uses the injected cancellation check, since
        // racing a real Task would mostly pass for the wrong reason.
        let manager = FileSyncManager()
        let previous = RiskyName(id: "/prev/tail ", relativePath: "tail ", currentName: "tail ",
                                 sanitizedName: "tail", reason: "a trailing space", isDirectory: false)
        manager.riskyNames = [previous]

        let hazard = FileNode(id: "/scan/other ", name: "other ", isDirectory: false)
        await manager.detectRiskyNames(in: [hazard], root: URL(fileURLWithPath: "/scan"),
                                       provider: .dropBox, isCancelled: { true })

        #expect(manager.riskyNames == [previous], "a superseded scan must not replace the finding")
    }

    @MainActor
    @Test func anUnreadableProviderRootIsNotItselfOfferedAsARename() async {
        // `buildTree` reports a permission-denied root as one unexplored marker at the root's own
        // path. Unguarded, the detector would flag the provider root's name and "Fix all" would
        // rename it (a rename needs only parent-write), dangling every path aimed at the root.
        let root = URL(fileURLWithPath: "/denied/Provider Root ")
        let marker = FileNode(id: root.path, name: "Provider Root ", isDirectory: true,
                              children: nil, isUnexplored: true)
        // Control: the detector would otherwise flag this name, so the fixture isn't simply safe.
        #expect(NameNormalizer.risky(name: marker.name, relativePath: marker.name,
                                     absolutePath: marker.id, isDirectory: true,
                                     provider: .oneDrive) != nil)

        let manager = FileSyncManager()
        await manager.detectRiskyNames(in: [marker], root: root, provider: .oneDrive)

        #expect(manager.riskyNames.isEmpty, "an unreadable root must never be offered as a rename")
    }

    @MainActor
    @Test func aRealEntryThatHappensToMatchTheRootPathIsStillScanned() async {
        // The guard keys on the unexplored marker, not the path, or a real entry at the root path
        // would be skipped.
        let root = URL(fileURLWithPath: "/readable")
        let child = FileNode(id: "/readable/tail ", name: "tail ", isDirectory: false)

        let manager = FileSyncManager()
        await manager.detectRiskyNames(in: [child], root: root, provider: .oneDrive)

        #expect(manager.riskyNames.map(\.currentName) == ["tail "])
    }

    // MARK: The single-file door (the pane row's "Fix name")

    @Test func theOneNodeCheckAgreesWithTheWholeTreeScan() {
        // The row menu and the batch share one rule. If they disagreed, a flagged name would have
        // no per-row fix, or a row would offer a fix the batch doesn't.
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
        // The menu item's help text quotes `sanitizedName`, and the fix runs through the batch's
        // `normalizeNames`, so both must propose the same name.
        let name = "Q3: report .pdf"
        let one = NameNormalizer.risky(name: name, relativePath: name, absolutePath: "/x/\(name)",
                                       isDirectory: false, provider: .oneDrive)
        let batch = NameNormalizer.evaluate(name: name, relativePath: name, absolutePath: "/x/\(name)",
                                            isDirectory: false, provider: .oneDrive)
        #expect(one?.sanitizedName == batch?.sanitizedName)
        #expect(one?.reason == batch?.reason)
    }
}
