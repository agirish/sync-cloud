import Testing
import Foundation
@testable import Sync

/// Pins the standing conflict policy: file collisions auto-resolve per policy, `.ask` and
/// every folder collision fall through to the prompt, and persistence parses safely.
@Suite struct ConflictPolicyTests {

    @Test func testFileCollisionsAutoResolvePerPolicy() {
        #expect(ConflictPolicy.keepBoth.autoResolution(isDirectory: false) == .keepBoth)
        #expect(ConflictPolicy.replace.autoResolution(isDirectory: false) == .replace)
        #expect(ConflictPolicy.skip.autoResolution(isDirectory: false) == .skip)
    }

    @Test func testAskAlwaysPrompts() {
        #expect(ConflictPolicy.ask.autoResolution(isDirectory: false) == nil)
        #expect(ConflictPolicy.ask.autoResolution(isDirectory: true) == nil)
    }

    @Test func testFolderCollisionsAlwaysPromptRegardlessOfPolicy() {
        for policy in ConflictPolicy.allCases {
            #expect(policy.autoResolution(isDirectory: true) == nil)
        }
    }

    @Test func testPersistedParsingFallsBackToAsk() {
        let suite = "ConflictPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ConflictPolicy.persisted(from: defaults) == .ask)
        defaults.set(ConflictPolicy.replace.rawValue, forKey: ConflictPolicy.defaultsKey)
        #expect(ConflictPolicy.persisted(from: defaults) == .replace)
        defaults.set("NONSENSE", forKey: ConflictPolicy.defaultsKey)
        #expect(ConflictPolicy.persisted(from: defaults) == .ask)
    }
}
