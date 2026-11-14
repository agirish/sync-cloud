import Testing
import Foundation
@testable import Sync

/// Pins the write half of the persisted-rule stores: an unencodable value must leave the saved
/// bytes exactly where they were, since losing the rules the user taught is expensive and
/// unexplainable. `UserDefaults.set(nil, forKey:)` is defined as `removeObject(forKey:)`, so
/// writing `try? encode(…)` would delete the whole store on a failed encode.
@Suite struct PersistedStoreWriteTests {

    /// A value the codec always refuses, so the failure path can be exercised on purpose. The real
    /// stores hold only `String`/`Int`/`Bool`/`UUID` and should never fail.
    private struct ThrowingEncodable: Encodable {
        struct Refused: Error {}
        func encode(to encoder: Encoder) throws { throw Refused() }
    }

    private let key = "phaseOnePersistedStore"

    @MainActor
    @Test func aFailedEncodeLeavesThePreviouslySavedStoreIntact() throws {
        let defaults = ScratchDefaults("PersistedStoreWrite")
        let good = [FilingRule(tokens: ["tesla"], destinationPath: "/root/Documents/Vehicles")]
        FileSyncManager.writePersistedStore(good, to: defaults, key: key, describing: "test store")
        let saved = try #require(defaults.data(forKey: key), "the good save must land first")

        FileSyncManager.writePersistedStore(ThrowingEncodable(), to: defaults,
                                            key: key, describing: "test store")

        // Not removed, and not replaced with anything else.
        #expect(defaults.data(forKey: key) == saved)
        // And it still decodes to the rules the user taught.
        let round = try #require(FileSyncManager.decodePersistedStore([FilingRule].self, from: defaults,
                                                                      key: key, describing: "test store"))
        #expect(round == good)
    }

    /// End to end through the real property, so the three setters are covered by their own type,
    /// not only by the helper they share.
    @MainActor
    @Test func theAutomationRuleSetterRoundTripsThroughTheHelper() async throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("PersistedStoreWriteAutomations")
        let rule = AutomationRule(name: "Invoices", matchMode: .all,
                                  conditions: [.mentionsAll(["invoice"])],
                                  destinationTemplate: "/root/Documents/Invoices")

        manager.upsertAutomationRule(rule)

        // A fresh manager on the same store reads it back: the write really reached defaults.
        let reread = FileSyncManager()
        reread.filingRuleDefaults = manager.filingRuleDefaults
        reread.ensureAutomationRulesLoaded()
        let round = try #require(reread.automationRules.first { $0.id == rule.id })
        #expect(round.name == rule.name)
        #expect(round.destinationTemplate == rule.destinationTemplate)
        #expect(round.conditions == rule.conditions)
    }

    /// The three setters are near-identical and each names its own defaults key, which the helper
    /// can't check: a copy-pasted key would write the wrong store and read back empty. These two
    /// round-trip the remaining pair through the real properties and check they don't tread on
    /// each other in one `UserDefaults`.
    @MainActor
    @Test func theWordRejectionSetterRoundTripsUnderItsOwnKey() throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("PersistedStoreWriteWords")
        let words = [FilingWordRejection(word: "india", path: "/root/Travel/India"),
                     FilingWordRejection(word: "acme", path: "/root/Work")]

        manager.filingWordRejections = words

        #expect(manager.filingWordRejections == words)
        // Written under the word-rejections key specifically, not whichever key was pasted last.
        #expect(manager.filingRuleDefaults.data(forKey: FileSyncManager.wordRejectionsDefaultsKey) != nil)
        #expect(manager.filingRejections.isEmpty, "rejections must not see the word rejections' payload")
    }

    @MainActor
    @Test func theFilingRejectionSetterRoundTripsUnderItsOwnKey() throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("PersistedStoreWriteRejections")
        let rejections = [FilingRejection(tokens: ["tesla"], path: "/root/Wrong"),
                          FilingRejection(tokens: ["acme"], path: "/root/AlsoWrong")]

        manager.filingRejections = rejections

        #expect(manager.filingRejections == rejections)
        #expect(manager.filingRuleDefaults.data(forKey: FileSyncManager.rejectionsDefaultsKey) != nil)
        #expect(manager.filingWordRejections.isEmpty, "word rejections must not see the rejections' payload")
    }

    /// Both stores live in ONE `UserDefaults`, so writing one must leave the other alone. A shared
    /// key would pass every single-store test above and only surface here.
    @MainActor
    @Test func theTwoFilingStoresCoexistInOneDefaults() throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("PersistedStoreWriteBoth")
        let words = [FilingWordRejection(word: "tesla", path: "/root/Vehicles")]
        let rejections = [FilingRejection(tokens: ["tesla"], path: "/root/Wrong")]

        manager.filingWordRejections = words
        manager.filingRejections = rejections

        #expect(manager.filingWordRejections == words)
        #expect(manager.filingRejections == rejections)
    }
}
