import Foundation
import Testing
import Events
@testable import Sync

/// Review fixes with no other natural home, one rule per section.
@Suite struct ReviewFixesTests {

    // MARK: Case sensitivity of a destination that does not exist yet

    @Test func caseWalkTakesTheAnswerFromTheNearestExistingAncestor() {
        // The shape a bulk sync always asks about: the file is missing on the destination, so only
        // an ancestor can answer. Falling back to "folds case" at the leaf would rename `README.md`
        // to `README 2.md` on a case-sensitive volume just because `Readme.md` is in the batch.
        let target = URL(fileURLWithPath: "/vol/deep/dir/not-created-yet.txt")
        var asked: [String] = []
        let answer = FileSyncManager.caseSensitivityWalkingUp(from: target) { probe in
            asked.append(probe.lastPathComponent)
            return probe.path == "/vol" ? true : nil   // only the mounted root can answer
        }
        #expect(answer == true)
        #expect(asked.first == "not-created-yet.txt")   // leaf first...
        #expect(asked.contains("vol"))                  // ...then up to the volume
    }

    @Test func caseWalkFoldsWhenNothingCanAnswer() {
        // Unanswerable all the way to "/" keeps the safe direction: folding at worst uniquifies a
        // name needlessly, while wrongly claiming case sensitivity lets two parallel writers pick
        // the same destination file.
        #expect(FileSyncManager.caseSensitivityWalkingUp(from: URL(fileURLWithPath: "/a/b/c")) { _ in nil } == false)
    }

    /// The undo's case check asks about `item.from`, the path being restored to, which is usually
    /// absent. `volumeSupportsCaseSensitiveNames(for:)` throws there and falls back to `false`,
    /// which makes `sameItemAsMoved` true on a case-sensitive volume and waves the undo past the
    /// occupant guard. So it must use the walking probe. A source scan, because on a
    /// case-insensitive disk both probes answer `false` and can't be told apart by behaviour.
    @Test func theUndosCaseCheckUsesTheProbeThatSurvivesAnAbsentPath() throws {
        let url = URL(fileURLWithPath: #filePath)          // …/Tests/Sync/<this>.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileSyncManager+Undo.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // Non-vacuity: the decision this is about still exists and still reads a volume probe.
        let line = try #require(source.range(of: "let sameItemAsMoved = "),
                                "the undo's case check was renamed — this scan measures nothing")
        let decision = String(source[line.lowerBound...].prefix(220))

        #expect(decision.contains("volumeSupportsCaseSensitiveNamesForNewItem"),
                "the undo asks a probe that throws for an absent path, so it always folds")
        #expect(!decision.contains("volumeSupportsCaseSensitiveNames(for:"),
                "the undo is back on the probe that cannot answer for a path being restored to")
    }

    @Test func caseWalkStopsAtTheFirstAnswerRatherThanTheOutermost() {
        // A nested mount answers for itself; the walk must not keep climbing past it.
        let answer = FileSyncManager.caseSensitivityWalkingUp(from: URL(fileURLWithPath: "/outer/inner/new.txt")) { probe in
            switch probe.path {
            case "/outer/inner": return true
            case "/outer", "/": return false
            default: return nil
            }
        }
        #expect(answer == true)
    }

    // MARK: The sanitizer's own output must be storable everywhere

    @Test func sanitizingAnExoticTrailingSpaceDoesNotLeaveAPlainOne() {
        // The fold turns every exotic space into an ASCII one, ends included, so without a trim the
        // fix for "report\u{00A0}" would be "report ": what Dropbox and OneDrive refuse to store.
        let risky = NameNormalizer.evaluate(name: "report\u{00A0}", relativePath: "report\u{00A0}",
                                            absolutePath: "/root/report\u{00A0}", isDirectory: false,
                                            provider: .iCloud)
        #expect(risky?.sanitizedName == "report")
        #expect(ProviderNameRules.violation(name: risky?.sanitizedName ?? "", provider: .dropBox) == nil)
        #expect(ProviderNameRules.violation(name: risky?.sanitizedName ?? "", provider: .oneDrive) == nil)
    }

    @Test func aNameOfNothingButExoticSpacesBecomesUntitled() {
        // Folded to " ", which is not empty, so without the trim the `untitled` fallback never fires
        // and the fix on offer is a single-space name.
        let risky = NameNormalizer.evaluate(name: "\u{00A0}", relativePath: "\u{00A0}",
                                            absolutePath: "/root/\u{00A0}", isDirectory: false,
                                            provider: .iCloud)
        #expect(risky?.sanitizedName == "untitled")
    }

    @Test func aPlainTrailingSpaceOnAPermissiveProviderIsStillNotFlagged() {
        // The trim is scoped to names the fold changed. Trimming always would flag every
        // plain-trailing-space name on iCloud as risky, a far wider claim than this detector makes.
        let risky = NameNormalizer.evaluate(name: "report ", relativePath: "report ",
                                            absolutePath: "/root/report ", isDirectory: false,
                                            provider: .iCloud)
        #expect(risky == nil)
    }

    // MARK: A learned rule must never be born unrunnable

    @Test func aDestinationFolderContainingBracesIsNotProposedAsARule() {
        // Stored relative, a `{…}` reads as a TEMPLATE token, so the evaluator would report the rule
        // "needs {final}" on every run and it could never file anything.
        #expect(AutomationRuleProposer.propose(fileName: "acme-invoice.pdf",
                                               destinationRelativePath: "Work/Q3 {final}") == nil)
    }

    @Test func anOrdinaryDestinationStillProposesARule() {
        // The control: the brace guard must not have turned the offer off in general.
        let proposal = AutomationRuleProposer.propose(fileName: "acme-invoice.pdf",
                                                      destinationRelativePath: "Work/Acme")
        #expect(proposal != nil)
        #expect(proposal?.rule.destinationTemplate == "Work/Acme")
    }

    // MARK: A store that exists but cannot be read is not "no rules"

    @MainActor @Test func anAbsentPersistedStoreIsSilentAndLeavesNoBackup() throws {
        // First run is not a failure: no data, no warning, nothing stashed.
        let defaults = ScratchDefaults("review-fixes")

        let decoded = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults,
                                                           key: "automationRules",
                                                           describing: "automation rules")
        #expect(decoded == nil)
        #expect(defaults.data(forKey: "automationRules.unreadable") == nil)
    }

    // MARK: Regressions found reviewing the fixes above

    /// Which local paths a provider's Location claims, by one provider of `type` rooted at `root`.
    /// A Location can be any folder, so it claims its own tree and nothing beside it: pointed at
    /// home, `synccloud sync -L ~/scratch -R ~/scratch2` would silently skip every name OneDrive
    /// forbids. A bare "CloudStorage" component elsewhere doesn't count, `/Volumes/<mount>` still
    /// claims its own tree (or a CLI root inside it loses the destination-name guard), and "/" or
    /// "/Users" claim nothing. The control: the real account folder still claims its siblings.
    @Test(arguments: [
        ("OneDrive-Personal", CloudProvider.ProviderType.oneDrive, "/Users/u", "/Users/u/scratch", CloudProvider.ProviderType?.none),
        ("Dropbox", .dropBox, "/Users/u/Projects/CloudStorage/notes/deep/root", "/Users/u/Projects/CloudStorage/notes/other", nil),
        ("Dropbox", .dropBox, "/Users/u/Projects/CloudStorage/notes/deep/root", "/Users/u/Projects/CloudStorage/notes/deep/root/x", .dropBox),
        ("GoogleDrive", .googleDrive, "/Volumes/GoogleDrive", "/Volumes/GoogleDrive/Reports/q1.txt", .googleDrive),
        ("GoogleDrive", .googleDrive, "/Volumes/GoogleDrive", "/Volumes/Backup/q1.txt", nil),
        ("OneDrive-Personal", .oneDrive, "/Users/u/Documents", "/Users/u/Documents/deck.txt", .oneDrive),
        ("OneDrive-Personal", .oneDrive, "/Users/u/Documents", "/Users/u/scratch", nil),
        ("OneDrive-Personal", .oneDrive, "/", "/Users/u/scratch", nil),
        ("OneDrive-Personal", .oneDrive, "/Users", "/Users/u/scratch", nil),
        ("OneDrive-Personal", .oneDrive, "/Volumes", "/Users/u/scratch", nil),
        ("OneDrive-Personal", .oneDrive, "/Users/u/Library/CloudStorage/OneDrive-Personal/Documents",
         "/Users/u/Library/CloudStorage/OneDrive-Personal/Photos", .oneDrive),
    ])
    func aProviderClaimsOnlyWhatItsRootContains(id: String, type: CloudProvider.ProviderType, root: String,
                                                path: String, expected: CloudProvider.ProviderType?) {
        let names = ["OneDrive-Personal": ("OneDrive", "onedrive"), "Dropbox": ("Dropbox", "dropbox"),
                     "GoogleDrive": ("Google Drive", "googledrive")]
        let (displayName, imageName) = names[id]!
        let providers = [CloudProvider(id: id, displayName: displayName, imageName: imageName, rootPath: root, type: type)]
        #expect(CloudProvider.inferredType(forPath: path, among: providers) == expected,
                "a provider rooted at \(root) answered wrongly for \(path)")
    }

    @MainActor @Test func twoStoresSharingAKeyNameEachKeepTheirOwnBackup() throws {
        // The one-shot report gate must not key on the key name alone, or the first store read
        // silences, and skips the backup for, every other store holding that key.
        let a = ScratchDefaults("review-fixes")
        let b = ScratchDefaults("review-fixes")
        let key = "automationRules"
        a.set(Data("corrupt-A".utf8), forKey: key)
        b.set(Data("corrupt-B".utf8), forKey: key)

        _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: a, key: key, describing: "rules")
        _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: b, key: key, describing: "rules")

        #expect(a.data(forKey: key + ".unreadable") == Data("corrupt-A".utf8))
        #expect(b.data(forKey: key + ".unreadable") == Data("corrupt-B".utf8),
                "the second store's corruption must be preserved too")
    }

    /// Counts every `set(_:forKey:)` so a re-write of an unchanged backup is visible.
    private final class CountingDefaults: UserDefaults {
        nonisolated(unsafe) static var writes = 0
        override func set(_ value: Any?, forKey defaultName: String) {
            Self.writes += 1
            super.set(value, forKey: defaultName)
        }
    }

    @MainActor @Test func rereadingACorruptStoreDoesNotRewriteItsBackupEveryTime() throws {
        // These getters are hot (a scan reads them per file), so an unconditional backup `set` would
        // rewrite the payload to cfprefsd thousands of times per scan while the store is corrupt.
        // The log line's rate limit doesn't cover the write.
        let suiteName = "review-fixes-\(UUID().uuidString)"
        let defaults = try #require(CountingDefaults(suiteName: suiteName))
        defer { wipeDefaultsSuite(suiteName) }
        let key = "automationRules"
        defaults.set(Data("corrupt".utf8), forKey: key)

        let decoded = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults,
                                                           key: key, describing: "rules")
        #expect(decoded == nil, "undecodable data must not read as a successfully-empty store")
        #expect(defaults.data(forKey: key + ".unreadable") == Data("corrupt".utf8),
                "the first read must still preserve the payload")

        CountingDefaults.writes = 0
        for _ in 0..<50 {
            _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults, key: key, describing: "rules")
        }
        #expect(CountingDefaults.writes == 0, "an unchanged backup must not be re-written per read")
        // And the invariant the skip must not cost: the bytes are still there.
        #expect(defaults.data(forKey: key + ".unreadable") == Data("corrupt".utf8))

        // A store whose corruption CHANGES is backed up again — the skip is "same bytes", not
        // "already backed up once".
        defaults.set(Data("different-corruption".utf8), forKey: key)
        CountingDefaults.writes = 0
        _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults, key: key, describing: "rules")
        #expect(CountingDefaults.writes == 1)
        #expect(defaults.data(forKey: key + ".unreadable") == Data("different-corruption".utf8))
    }
}
