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
    @Test func theProposedNameIsComputedWithTheScannedProvidersRules() async throws {
        // The ruleset travels on each RESULT, not on the manager: `sanitizedName` is computed
        // during the scan, and "Fix all" renames to that stored string. So the thing worth pinning
        // is the proposed name, not a remembered provider — a colon is legal on iCloud and illegal
        // on OneDrive, so scanning the same file under the two rulesets must differ here.
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
        // A caller that does not ask for the name check must leave the previous finding exactly
        // as it found it. Publishing an empty list would read as "nothing is wrong" and take the
        // chip off screen for a reason the user never triggered.
        let root = try makeCanonicalTempRoot(prefix: "FilingNamesPairing")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Downloads/a.pdf"))

        let manager = FileSyncManager()
        // Stand in for a completed OneDrive scan: results, and the ruleset that produced them.
        manager.riskyNames = [RiskyName(id: "/prev/tail ", relativePath: "tail ",
                                        currentName: "tail ", sanitizedName: "tail",
                                        reason: "a trailing space", isDirectory: false)]

        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                            providerRoot: root)

        #expect(manager.riskyNames.count == 1)
    }

    @MainActor
    @Test func aCancelledDetectionDoesNotReplaceTheNamesOnScreen() async {
        // A superseded scan must publish nothing: the finding on screen belongs to the scan that
        // produced it, and a newer scan that is cancelled before it finishes knows nothing better.
        // Landing a partial or empty result here would change the chip's count — and which list
        // the user is looking at — on the strength of a scan that was abandoned.
        //
        // Asserted through the injected cancellation check rather than by racing a real Task: a
        // timing-dependent version of this passes for the wrong reason most of the time.
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
        // `buildTree` reports a permission-denied root as ONE unexplored marker carrying the
        // root's own path. The detector cannot tell that from a real entry, so it would flag the
        // provider root's name — and "Fix all" would rename it. A rename needs only parent-write,
        // so it would succeed, dangling the configured root and every path aimed at it.
        //
        // The standalone scan has always guarded this. The folded one was written without it,
        // which is why the check now lives in one shared predicate.
        let root = URL(fileURLWithPath: "/denied/Provider Root ")
        let marker = FileNode(id: root.path, name: "Provider Root ", isDirectory: true,
                              children: nil, isUnexplored: true)
        // Sanity: the name IS one the detector would otherwise flag, so this test cannot pass
        // merely because the fixture was safe.
        #expect(NameNormalizer.risky(name: marker.name, relativePath: marker.name,
                                     absolutePath: marker.id, isDirectory: true,
                                     provider: .oneDrive) != nil)

        let manager = FileSyncManager()
        await manager.detectRiskyNames(in: [marker], root: root, provider: .oneDrive)

        #expect(manager.riskyNames.isEmpty, "an unreadable root must never be offered as a rename")
    }

    @MainActor
    @Test func aRealEntryThatHappensToMatchTheRootPathIsStillScanned() async {
        // The guard keys on the unexplored MARKER, not merely on the path — otherwise a readable
        // tree whose single entry sits at the root path would be silently skipped.
        let root = URL(fileURLWithPath: "/readable")
        let child = FileNode(id: "/readable/tail ", name: "tail ", isDirectory: false)

        let manager = FileSyncManager()
        await manager.detectRiskyNames(in: [child], root: root, provider: .oneDrive)

        #expect(manager.riskyNames.map(\.currentName) == ["tail "])
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
