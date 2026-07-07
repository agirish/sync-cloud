import Testing
import Foundation

/// Layering pin: the Sync engine must not link any UI framework.
///
/// Sync is the non-UI engine layer — views live in FileExplorer/Dashboard. This test
/// scans every source file in the package and fails if `import SwiftUI` or
/// `import AppKit` creeps back in, so the layering rule is self-enforcing.
/// (CoreTransferable and UniformTypeIdentifiers are fine: they are data-transfer /
/// type-metadata frameworks, not UI.)
struct LayeringPinTests {

    /// Imports that must never appear in Modules/Sync/Sources.
    private static let forbiddenImports = ["import SwiftUI", "import AppKit"]

    /// Files allowed to keep a forbidden import, keyed by file name with the
    /// justification as the value. Currently empty — keep it that way.
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

        // Guard against the scan silently scanning nothing (e.g. after a directory rename).
        #expect(scannedCount > 0, "Layering pin scanned no Swift files under \(sourcesRoot.path)")
        #expect(violations.isEmpty, "UI framework imports crept back into the Sync engine:\n\(violations.joined(separator: "\n"))")
    }
}
