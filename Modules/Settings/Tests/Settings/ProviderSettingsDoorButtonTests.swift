import Foundation
import Testing
@testable import Settings

/// The provider-settings door in Settings ▸ Sources, one of two surfaces that offer it (the
/// sidebar's context menu is pinned in Dashboard). Source scans, because a SwiftUI button can't be
/// driven from a unit test: the button exists in the account editor, is gated on the door being
/// openable, and routes through the shared opener.
@Suite struct ProviderSettingsDoorButtonTests {

    /// Comments stripped, as in every source scan here, so prose can't satisfy or fail it.
    static func source() throws -> String {
        SourceComments.stripped(try settingsSource("SettingsView.swift", minLength: 3_000))
    }

    /// The account editor offers the door, gated on `canOpen` (absent, not disabled, when the
    /// vendor's app is missing), and opens it through the shared opener. The door comes from the
    /// provider, not a second table: one door per provider, declared once on `CloudProvider`,
    /// keeps the two surfaces from disagreeing.
    @Test func theAccountEditorOffersTheDoorBehindCanOpen() throws {
        let code = try Self.source()
        let gate = try #require(
            code.range(of: "ProviderSettingsOpener.canOpen(door)"),
            "the door button's availability gate was not found — this scan is vacuous")
        let body = String(code[gate.upperBound...].prefix(160))
        #expect(body.contains("Button(title) { ProviderSettingsOpener.open(door) }"),
                "the door button no longer routes through the shared opener")
        let before = String(code[..<gate.lowerBound].suffix(200))
        #expect(before.contains("provider.settingsDoor") && before.contains("provider.settingsDoorTitle"),
                "the button's door and title no longer come from the provider itself")
    }
}
