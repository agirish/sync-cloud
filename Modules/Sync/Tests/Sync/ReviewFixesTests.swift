import Foundation
import Testing
import Events
@testable import Sync

/// Regression coverage for a batch of review findings whose fixes have no other natural home.
@Suite struct ReviewFixesTests {

    // MARK: Case sensitivity of a destination that does not exist yet

    @Test func caseWalkTakesTheAnswerFromTheNearestExistingAncestor() {
        // The shape a bulk sync always asks about: the file is missing on the destination side, so
        // only an ancestor can answer. Before the walk, the probe failed on the leaf and the caller
        // fell back to "folds case" — on a case-SENSITIVE volume that renamed `README.md` to
        // `README 2.md` merely because `Readme.md` was in the same batch.
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
        // The fold turns every exotic space into an ASCII one, ends included — so on a provider with
        // no affix rule the proposed fix for "report\u{00A0}" was "report ", still invisibly
        // different from "report" and exactly what Dropbox and OneDrive refuse to store.
        let risky = NameNormalizer.evaluate(name: "report\u{00A0}", relativePath: "report\u{00A0}",
                                            absolutePath: "/root/report\u{00A0}", isDirectory: false,
                                            provider: .iCloud)
        #expect(risky?.sanitizedName == "report")
        #expect(ProviderNameRules.violation(name: risky?.sanitizedName ?? "", provider: .dropBox) == nil)
        #expect(ProviderNameRules.violation(name: risky?.sanitizedName ?? "", provider: .oneDrive) == nil)
    }

    @Test func aNameOfNothingButExoticSpacesBecomesUntitled() {
        // Folded to " ", which is not empty — so the `untitled` fallback never fired and the fix on
        // offer was a single-space name.
        let risky = NameNormalizer.evaluate(name: "\u{00A0}", relativePath: "\u{00A0}",
                                            absolutePath: "/root/\u{00A0}", isDirectory: false,
                                            provider: .iCloud)
        #expect(risky?.sanitizedName == "untitled")
    }

    @Test func aPlainTrailingSpaceOnAPermissiveProviderIsStillNotFlagged() {
        // The trim is scoped to names the fold actually changed. Trimming unconditionally would
        // start reporting every plain-trailing-space name on iCloud as risky — a much wider claim
        // than this detector makes.
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

    @MainActor @Test func anUnreadablePersistedStoreIsReportedAndPreserved() throws {
        let suiteName = "review-fixes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "automationRules"
        defaults.set(Data("not json at all".utf8), forKey: key)

        let decoded = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults,
                                                           key: key, describing: "automation rules")

        #expect(decoded == nil, "undecodable data must not read as a successfully-empty store")
        // The raw bytes are set aside, so the next edit's overwrite is no longer the end of them —
        // the failure mode was that a corrupt store silently became [] and was then replaced.
        #expect(defaults.data(forKey: key + ".unreadable") == Data("not json at all".utf8))
    }

    @MainActor @Test func anAbsentPersistedStoreIsSilentAndLeavesNoBackup() throws {
        // First run is not a failure: no data, no warning, nothing stashed.
        let suiteName = "review-fixes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let decoded = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults,
                                                           key: "automationRules",
                                                           describing: "automation rules")
        #expect(decoded == nil)
        #expect(defaults.data(forKey: "automationRules.unreadable") == nil)
    }

    @MainActor @Test func areadablePersistedStoreDecodesUnchanged() throws {
        let suiteName = "review-fixes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rules = [AutomationRule(name: "Acme", matchMode: .all,
                                    conditions: [.nameMatches("*acme*")], destinationTemplate: "Work/Acme")]
        defaults.set(try JSONEncoder().encode(rules), forKey: "automationRules")

        let decoded = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults,
                                                           key: "automationRules",
                                                           describing: "automation rules")
        #expect(decoded?.count == 1)
        #expect(decoded?.first?.name == "Acme")
    }


    // MARK: Regressions found reviewing the fixes above

    @Test func aBroadProviderOverrideDoesNotRetypeEveryLocalFolder() {
        // A provider's Location is user-settable to any folder. Pointed at the home directory, the
        // claim used to swallow every path under it, so `synccloud sync -L ~/scratch -R ~/scratch2`
        // — two purely local folders — silently started skipping every name OneDrive forbids.
        let overridden = [CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive", imageName: "onedrive",
                                        path: "/Users/u", type: .oneDrive)]
        #expect(CloudProvider.inferredType(forPath: "/Users/u/scratch", among: overridden) == nil)
    }

    @Test func aFolderNamedCloudStorageElsewhereIsNotAProviderAccount() {
        // The widening matched a bare "CloudStorage" component ANYWHERE, so a project folder that
        // happens to be called that handed its siblings Dropbox's rules.
        let providers = [CloudProvider(id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
                                       path: "/Users/u/Projects/CloudStorage/notes/deep/root", type: .dropBox)]
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Projects/CloudStorage/notes/other",
                                           among: providers) == nil)
        // Its own root still claims, as before.
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Projects/CloudStorage/notes/deep/root/x",
                                           among: providers) == .dropBox)
    }

    @Test func theRealAccountFolderStillClaimsItsSiblings() {
        // The control: the case the widening exists for must keep working.
        let providers = [CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive", imageName: "onedrive",
                                       path: "/Users/u/Library/CloudStorage/OneDrive-Personal/Documents",
                                       type: .oneDrive)]
        #expect(CloudProvider.inferredType(forPath: "/Users/u/Library/CloudStorage/OneDrive-Personal/Photos",
                                           among: providers) == .oneDrive)
    }

    @MainActor @Test func anUnreadableLegacyStoreDoesNotBurnTheOneWayMigrationFlag() throws {
        // The migration sets a permanent "already migrated" flag and nothing consults the legacy
        // store afterwards. Reading an unreadable store as "no rules" therefore orphaned every
        // remembered rule the user had taught, forever, on one failed decode.
        let suiteName = "review-fixes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not json".utf8), forKey: FileSyncManager.rulesDefaultsKey)

        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.filingRuleDefaults = defaults
        manager.migrateFilingRulesToAutomations()

        #expect(defaults.bool(forKey: FileSyncManager.filingRulesMigratedKey) == false,
                "an unreadable store must leave the migration to retry, not mark itself done")
    }

    @MainActor @Test func anAbsentLegacyStoreStillCompletesTheMigrationOnce() throws {
        // The control: a genuinely empty legacy store is the ordinary case and must still settle,
        // or every launch would re-run the migration forever.
        let suiteName = "review-fixes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.filingRuleDefaults = defaults
        manager.migrateFilingRulesToAutomations()

        #expect(defaults.bool(forKey: FileSyncManager.filingRulesMigratedKey) == true)
    }

    @MainActor @Test func twoStoresSharingAKeyNameEachKeepTheirOwnBackup() throws {
        // The one-shot report gate was keyed on the key NAME alone, so whichever store was read
        // first silenced — and skipped the backup for — every other store holding that key.
        let nameA = "review-fixes-\(UUID().uuidString)"
        let nameB = "review-fixes-\(UUID().uuidString)"
        let a = try #require(UserDefaults(suiteName: nameA))
        let b = try #require(UserDefaults(suiteName: nameB))
        defer {
            a.removePersistentDomain(forName: nameA)
            b.removePersistentDomain(forName: nameB)
        }
        let key = "automationRules"
        a.set(Data("corrupt-A".utf8), forKey: key)
        b.set(Data("corrupt-B".utf8), forKey: key)

        _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: a, key: key, describing: "rules")
        _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: b, key: key, describing: "rules")

        #expect(a.data(forKey: key + ".unreadable") == Data("corrupt-A".utf8))
        #expect(b.data(forKey: key + ".unreadable") == Data("corrupt-B".utf8),
                "the second store's corruption must be preserved too")
    }
}
