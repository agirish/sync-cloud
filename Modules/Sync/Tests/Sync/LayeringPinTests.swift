import Testing
import Foundation

/// The Sync engine must not link a UI framework: views live in FileExplorer and Dashboard. Scans
/// every source file in the package for `import SwiftUI` or `import AppKit`. CoreTransferable and
/// UniformTypeIdentifiers are fine; they describe data, not UI.
struct LayeringPinTests {

    /// Imports that must never appear in Modules/Sync/Sources.
    private static let forbiddenImports = ["import SwiftUI", "import AppKit"]

    /// Files allowed a forbidden import, by file name, with the justification as the value. Empty;
    /// keep it that way.
    private static let allowlist: [String: String] = [:]

    @Test func syncSourcesLinkNoUIFramework() throws {
        // Tests/Sync/LayeringPinTests.swift -> package root is three levels up.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/Sync
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let sourcesRoot = packageRoot.appendingPathComponent("Sources")

        let enumerator = try #require(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil),
            "Could not enumerate \(sourcesRoot.path)"
        )

        var scannedCount = 0
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedCount += 1
            if Self.allowlist[url.lastPathComponent] != nil { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for forbidden in Self.forbiddenImports where trimmed.hasPrefix(forbidden) {
                    violations.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }

        // A scan that read nothing (say, after a folder rename) must not pass.
        #expect(scannedCount > 0, "Layering pin scanned no Swift files under \(sourcesRoot.path)")
        #expect(violations.isEmpty, "UI framework imports crept back into the Sync engine:\n\(violations.joined(separator: "\n"))")
    }
}
