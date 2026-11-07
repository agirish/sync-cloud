import Foundation
import Testing

/// No app test reads or writes the user's live settings, Keychain or cloud folders.
///
/// The test host is SyncCloud.app, so `UserDefaults.standard` here is his live domain: his Hidden
/// from Claude list, his filing rules, his text size. Each type below falls back to it, or to the
/// real Keychain or `~/Library/CloudStorage`, when a test leaves an argument out, and nothing at
/// the call site says so. Like `SetupTestDraftScanTests`, these scans make every construction name
/// what it uses; `FileSyncManager.scratch()` and `SettingsManager.scratch()` are the short forms.
@Suite struct LiveSettingsScanTests {

    /// Every test file in this target, with its name.
    private static func files() throws -> [(name: String, source: String)] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Each call of `callee` in the target, read by label, with the file it is in.
    private static func calls(of callee: String) throws -> [(file: String, call: CallArguments, text: String)] {
        try files().flatMap { file in
            argumentLists(of: callee, in: file.source).map {
                (file.name, CallArguments($0), "\(callee)(\(normalizedCode($0).prefix(80))…")
            }
        }
    }

    /// `FileSyncManager()` keeps Keep separate and Filing's settings and rules on `.standard`.
    @Test func everySyncManagerNamesItsDefaults() throws {
        let calls = try Self.calls(of: "FileSyncManager(")
        try #require(!calls.isEmpty, "no FileSyncManager construction found — the scan is reading the wrong folder")
        let live = calls.filter { $0.call.value("defaults") == nil }.map { "\($0.file): \($0.text)" }
        #expect(live.isEmpty, "built on the user's live defaults — use FileSyncManager.scratch(): \(live)")
    }

    /// `SettingsManager()` reads `.standard`, and with `autoDiscover` lists the real
    /// `~/Library/CloudStorage` in the background, writing what it found after the test is gone.
    @Test func everySettingsManagerStaysOffTheMachine() throws {
        let calls = try Self.calls(of: "SettingsManager(")
        try #require(calls.count >= 5, "found \(calls.count) SettingsManager constructions — the scan is reading the wrong folder")
        let live = calls.filter {
            $0.call.value("autoDiscover") != "false" || $0.call.value("userDefaults") == nil
                || $0.call.value("cloudStorageLister") == nil
        }.map { "\($0.file): \($0.text)" }
        #expect(live.isEmpty, "discovers or reads the user's real setup — use SettingsManager.scratch(): \(live)")
    }

    /// The chat reads its Hidden from Claude list from `defaults` and its key from `readKey`; both
    /// default to his. With a key, a question builds the default engine, which records spend in
    /// `.standard` and calls the real API, so a chat given a key names its engine too.
    @Test func everyChatNamesItsDefaultsKeyAndEngine() throws {
        let calls = try Self.calls(of: "AskClaudeChat(")
        try #require(calls.count >= 20, "found \(calls.count) AskClaudeChat constructions — the scan is reading the wrong folder")
        let live = calls.filter {
            $0.call.value("defaults") == nil || $0.call.value("readKey") == nil
                || ($0.call.value("readKey") != "{nil}" && $0.call.value("makeEngine") == nil)
        }.map { "\($0.file): \($0.text)" }
        #expect(live.isEmpty, "reads the user's Hidden from Claude list, Keychain or spend: \(live)")
    }

    /// The engine records spend and reads the detail setting in its `defaults`.
    @Test func everyEngineNamesItsDefaults() throws {
        let calls = try Self.calls(of: "AskClaudeEngine(")
        try #require(calls.count >= 20, "found \(calls.count) AskClaudeEngine constructions — the scan is reading the wrong folder")
        let live = calls.filter { $0.call.value("defaults") == nil }.map { "\($0.file): \($0.text)" }
        #expect(live.isEmpty, "records spend in the user's live defaults: \(live)")
    }

    /// `.standard` is named only to clean up a scratch suite. Strings and comments are blanked
    /// first, so a scan's needle or a doc naming it does not count.
    @Test func noTestNamesTheLiveDomain() throws {
        var live: [String] = []
        var cleanups = 0
        for file in try Self.files() {
            let lexedFile = lexed(file.source)
            // Code only, strings and comments blanked. Whitespace goes only around `.` and `:`, so
            // `UserDefaults .standard` cannot hide and the next statement still starts a new word.
            let blanked = String(decoding: zip(lexedFile.bytes, lexedFile.roles)
                .map { $1 == .code ? $0 : UInt8(ascii: " ") }, as: UTF8.self)
            let code = blanked.replacingOccurrences(of: #"\s*([.:])\s*"#, with: "$1", options: .regularExpression)
            var rest = code[...]
            while let use = rest.range(of: "UserDefaults.standard") {
                let after = rest[use.upperBound...]
                let member = after.first == "." ? String(after.dropFirst().prefix { $0.isLetter }) : ""
                if member == "removePersistentDomain" || member == "removeSuite" {
                    cleanups += 1
                } else if !(after.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false) {
                    live.append("\(file.name): UserDefaults.standard\(member.isEmpty ? "" : "." + member)")
                }
                rest = after
            }
            // `defaults: .standard`, `userDefaults: .standard`: a call handed the live domain.
            rest = code[...]
            while let passed = rest.range(of: "efaults:.standard") {
                let after = rest[passed.upperBound...]
                if !(after.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false) {
                    live.append("\(file.name): …\(rest[passed])")
                }
                rest = after
            }
        }
        try #require(cleanups >= 1, "wipeDefaultsSuite's own cleanup was not found — the scan is matching nothing")
        #expect(live.isEmpty, "a test reads or writes the user's live domain: \(live)")
    }

    /// A bare `UserDefaults(suiteName:)` is wiped through `wipeDefaultsSuite`, which also removes
    /// its plist and records it for the next run's sweep; `removePersistentDomain` leaves the file
    /// in `~/Library/Preferences`. `ScratchDefaults` does this on its own.
    @Test func everyBareSuiteIsWiped() throws {
        var suites = 0
        var leaked: [String] = []
        for file in try Self.files() {
            let code = normalizedCode(file.source)
            for list in argumentLists(of: "UserDefaults(", in: file.source) {
                guard let name = CallArguments(list).value("suiteName") else { continue }
                suites += 1
                if !code.contains("wipeDefaultsSuite(\(name))") { leaked.append("\(file.name): suiteName: \(name)") }
            }
        }
        try #require(suites >= 5, "found \(suites) bare suites — the scan is reading the wrong folder")
        #expect(leaked.isEmpty, "a suite this file never wipes leaves its plist behind: \(leaked)")
    }
}
