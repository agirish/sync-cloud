import Foundation
import Testing
@testable import Settings

/// **The one non-colour carrier of which settings tab is open.**
///
/// `SettingsRail.railRow` paints selection as an accent fill and an on-accent label, and adds
/// `.isSelected`. Delete that one line and the rail paints identically: every geometry test, every
/// snapshot, every layout measurement stays green — and VoiceOver loses the only signal there is,
/// because colour is not a thing it can report. Nothing named `railRow`, `isSelected` or
/// `accessibilityAddTraits` anywhere in this package's tests.
///
/// **A source scan, deliberately, and this repo's own record is why.** Assertions against the live
/// accessibility tree pass *vacuously* without an assistive client attached — a caption test here
/// proved that the hard way — so a green trait assertion would be no evidence at all. This reads
/// the source instead, names the file it reads, and fails if that file cannot be found.
@Suite struct SettingsRailSelectionTraitTests {

    static let source: String = {
        let url = URL(fileURLWithPath: #filePath)          // …/Tests/Settings/<this>.swift
            .deletingLastPathComponent()                   // …/Tests/Settings
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // …/Settings (package)
            .appendingPathComponent("Sources/Settings/SettingsLayout.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    @Test func theRailRowStillCarriesTheSelectedTrait() throws {
        // The non-vacuity guard: an unreadable or truncated file must FAIL rather than hand every
        // `contains` below a haystack in which it quietly answers false.
        try #require(Self.source.count > 500,
                     "SettingsLayout.swift could not be read — the scan below would be vacuous")
        try #require(Self.source.contains("static func railRow("),
                     "railRow was renamed; this scan is no longer reading the rail's row")

        #expect(Self.source.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"),
                "the rail's selected row no longer announces that it is selected — colour is then the only carrier, and colour is not audible")
    }

    /// The other half, so the trait cannot quietly become unconditional: an unselected row must not
    /// claim it. A row that always announces "selected" is as useless as one that never does.
    @Test func theTraitIsConditional() throws {
        try #require(Self.source.count > 500)
        #expect(!Self.source.contains(".accessibilityAddTraits([.isSelected])"),
                "the trait is applied unconditionally, so every row announces as selected")
        #expect(!Self.source.contains(".accessibilityAddTraits(.isSelected)"),
                "the trait is applied unconditionally, so every row announces as selected")
    }
}
