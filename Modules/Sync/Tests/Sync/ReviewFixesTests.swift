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
}
