import Foundation
import Testing

/// No test here builds a `SettingsManager` that discovers on its own.
///
/// `autoDiscover` defaults to true and the lister to the real `~/Library/CloudStorage`, so a test
/// passing only `userDefaults:` lists the machine's cloud accounts in the background, can read
/// them into its verdict, and writes `lastKnownAccountFolders` into its suite after the test wiped
/// it, recreating the plist (`TestDefaults`). Every construction names all three.
@Suite struct SettingsDiscoveryScanTests {

    @Test func everyManagerNamesItsDefaultsAndListerAndDoesNotDiscover() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsDiscoveryScanTests.swift" }
        var constructions = 0
        var live: [String] = []
        for file in files {
            // Whole-line comments out, so a doc naming the call is not one.
            let source = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.drop { $0 == " " }.hasPrefix("//") }
                .joined(separator: "\n")
            var rest = source[...]
            while let open = rest.range(of: "SettingsManager(") {
                // Only the type itself: `XSettingsManager(` or `.SettingsManager(` are other names.
                let before = rest[..<open.lowerBound].last
                var depth = 1
                var end = open.upperBound
                while depth > 0, end < rest.endIndex {
                    switch rest[end] {
                    case "(": depth += 1
                    case ")": depth -= 1
                    default: break
                    }
                    end = rest.index(after: end)
                }
                let arguments = rest[open.upperBound..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if before.map({ !$0.isLetter && !$0.isNumber && $0 != "." }) ?? true {
                    constructions += 1
                    if !arguments.contains("autoDiscover: false") || !arguments.contains("userDefaults:")
                        || !arguments.contains("cloudStorageLister:") {
                        live.append("\(file.lastPathComponent): SettingsManager(\(arguments.prefix(70))…")
                    }
                }
                rest = rest[end...]
            }
        }
        try #require(constructions >= 15, "found \(constructions) SettingsManager constructions — the scan is reading the wrong folder")
        #expect(live.isEmpty, "discovers the machine's real cloud accounts: \(live)")
    }
}
