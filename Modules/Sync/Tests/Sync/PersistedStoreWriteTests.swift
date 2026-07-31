import Testing
import Foundation
@testable import Sync

/// Pins the WRITE half of the persisted-rule stores.
///
/// `readPersistedStore` has long gone to real lengths to keep an undecodable payload alive (it is
/// preserved under a sibling key rather than silently read as `[]`), because losing the rules the
/// user taught is expensive and unexplainable. The setters, meanwhile, were spelled
/// `defaults.set(try? JSONEncoder().encode(newValue), forKey:)` — and `UserDefaults.set(nil,
/// forKey:)` is *defined* as `removeObject(forKey:)`, so a failed encode did not skip the write, it
/// deleted the whole store. These tests pin the failure direction: an unencodable value must leave
/// the previously saved bytes exactly where they were.
@Suite struct PersistedStoreWriteTests {

    /// A value the codec always refuses, so the failure path can be exercised deliberately. The real
    /// stores are `String`/`Int`/`Bool`/`UUID` throughout and should never fail — which is the whole
    /// problem with failing open: the wipe could not be reproduced on purpose, only suffered.
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

    /// The mutation guard for the test above: it asserts "the bytes survived", which is only
    /// meaningful if the OLD spelling would have destroyed them. It would — this pins the
    /// `set(nil) == removeObject` semantic the whole finding rests on, so nobody has to take the
    /// commit message's word for it.
    @MainActor
    @Test func theOldSpellingWouldHaveRemovedTheKeyEntirely() throws {
        let defaults = ScratchDefaults("PersistedStoreWriteMutation")
        let good = [FilingRule(tokens: ["tesla"], destinationPath: "/root/Documents/Vehicles")]
        FileSyncManager.writePersistedStore(good, to: defaults, key: key, describing: "test store")
        #expect(defaults.data(forKey: key) != nil)

        // Verbatim the pre-fix expression.
        defaults.set(try? JSONEncoder().encode(ThrowingEncodable()), forKey: key)

        #expect(defaults.data(forKey: key) == nil, "set(nil:) removes the key — this is the wipe")
    }

    /// The happy path still writes, so the guard cannot be satisfied by never saving anything.
    @MainActor
    @Test func anEncodableValueIsStillPersisted() throws {
        let defaults = ScratchDefaults("PersistedStoreWriteHappy")
        let rules = [FilingRule(tokens: ["acme"], destinationPath: "/root/Work")]

        FileSyncManager.writePersistedStore(rules, to: defaults, key: key, describing: "test store")

        let round = try #require(FileSyncManager.decodePersistedStore([FilingRule].self, from: defaults,
                                                                      key: key, describing: "test store"))
        #expect(round == rules)
    }

    /// End-to-end through the real property, so the three setters are covered by their own type
    /// rather than only by the helper they now share.
    @MainActor
    @Test func theAutomationRuleSetterRoundTripsThroughTheHelper() async throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("PersistedStoreWriteAutomations")
        let rule = AutomationRule(name: "Invoices", matchMode: .all,
                                  conditions: [.mentionsAll(["invoice"])],
                                  destinationTemplate: "/root/Documents/Invoices")

        manager.upsertAutomationRule(rule)

        // A fresh manager on the same store reads it back — the write really reached defaults.
        let reread = FileSyncManager()
        reread.filingRuleDefaults = manager.filingRuleDefaults
        reread.ensureAutomationRulesLoaded()
        let round = try #require(reread.automationRules.first { $0.id == rule.id })
        #expect(round.name == rule.name)
        #expect(round.destinationTemplate == rule.destinationTemplate)
        #expect(round.conditions == rule.conditions)
    }

    /// The three setters are near-identical call sites that each name their OWN defaults key, and
    /// the helper cannot catch a copy-pasted key — a rules/rejections mix-up would simply write the
    /// wrong store and read back empty. These two pin the remaining pair by round-tripping through
    /// the real properties, and cross-check that they do not tread on each other despite sharing
    /// one `UserDefaults`.
    @MainActor
    @Test func theFilingRuleSetterRoundTripsUnderItsOwnKey() throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("PersistedStoreWriteRules")
        let rules = [FilingRule(tokens: ["tesla"], destinationPath: "/root/Documents/Vehicles"),
                     FilingRule(tokens: ["acme"], destinationPath: "/root/Work", enabled: false)]

        manager.filingRules = rules

        #expect(manager.filingRules == rules)
        // Written under the rules key specifically, not whichever key was pasted last.
        #expect(manager.filingRuleDefaults.data(forKey: FileSyncManager.rulesDefaultsKey) != nil)
        #expect(manager.filingRejections.isEmpty, "rejections must not see the rules' payload")
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
        #expect(manager.filingRules.isEmpty, "rules must not see the rejections' payload")
    }

    /// Both stores live in ONE `UserDefaults`, so writing one must leave the other alone. A shared
    /// key would pass every single-store test above and only surface here.
    @MainActor
    @Test func theTwoFilingStoresCoexistInOneDefaults() throws {
        let manager = FileSyncManager()
        manager.filingRuleDefaults = ScratchDefaults("PersistedStoreWriteBoth")
        let rules = [FilingRule(tokens: ["tesla"], destinationPath: "/root/Vehicles")]
        let rejections = [FilingRejection(tokens: ["tesla"], path: "/root/Wrong")]

        manager.filingRules = rules
        manager.filingRejections = rejections

        #expect(manager.filingRules == rules)
        #expect(manager.filingRejections == rejections)
    }
}
