import Foundation
import Testing
@testable import Settings

/// **The provider-settings door in Settings ▸ Sources** — the second of the two surfaces that
/// offer it (the other is the sidebar's context menu, pinned in the Dashboard package). Source
/// scans, because a SwiftUI button is undrivable from a unit test; what is worth pinning is that
/// the button exists in the account editor, is gated on the door being openable, and routes
/// through the one shared opener rather than a private spelling of it.
@Suite struct ProviderSettingsDoorButtonTests {

    static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Settings/SettingsView.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read SettingsView.swift — this scan would be vacuous")
        try #require(raw.count > 3000, "the file is implausibly short — the scan is vacuous")
        // Comments stripped, as every source scan in this project does — a scan that reads
        // comments is asserting about what the code says about itself.
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The account editor offers the door, gated on `canOpen` — absent, not disabled, when the
    /// vendor's app is missing — and opens it through the shared opener.
    @Test func theAccountEditorOffersTheDoorBehindCanOpen() throws {
        let code = try Self.source()
        let gate = try #require(
            code.range(of: "ProviderSettingsOpener.canOpen(door)"),
            "the door button's availability gate was not found — this scan is vacuous")
        let body = String(code[gate.upperBound...].prefix(160))
        #expect(body.contains("Button(title) { ProviderSettingsOpener.open(door) }"),
                "the door button no longer routes through the shared opener")
    }

    /// The gate reads the door off the provider, not off a second table: one door per provider,
    /// declared once on `CloudProvider`, is what keeps the two surfaces from disagreeing.
    @Test func theButtonReadsTheProvidersOwnDoor() throws {
        let code = try Self.source()
        let gate = try #require(code.range(of: "ProviderSettingsOpener.canOpen(door)"))
        let before = String(code[..<gate.lowerBound].suffix(200))
        #expect(before.contains("provider.settingsDoor") && before.contains("provider.settingsDoorTitle"),
                "the button's door and title no longer come from the provider itself")
    }
}
