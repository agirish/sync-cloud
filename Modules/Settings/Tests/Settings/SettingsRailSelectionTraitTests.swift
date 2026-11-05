import Foundation
import Testing
@testable import Settings

/// The one non-colour carrier of which settings tab is open. `SettingsRail.railRow` paints
/// selection as an accent fill and an on-accent label, and adds `.isSelected`. Without that line
/// the rail paints identically and every geometry and snapshot test stays green, while VoiceOver
/// loses the only signal, since it can't report colour.
///
/// A source scan, because assertions against the live accessibility tree pass vacuously without
/// an assistive client attached. It names the file it reads and fails if it can't be found.
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
        // An unreadable or truncated file must fail rather than give every `contains` below a
        // haystack where it quietly answers false.
        try #require(Self.source.count > 500,
                     "SettingsLayout.swift could not be read — the scan below would be vacuous")
        try #require(Self.source.contains("static func railRow("),
                     "railRow was renamed; this scan is no longer reading the rail's row")

        #expect(Self.source.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"),
                "the rail's selected row no longer announces that it is selected — colour is then the only carrier, and colour is not audible")
    }

    /// The trait must not become unconditional: an unselected row must not claim it. A row that
    /// always announces "selected" is as useless as one that never does.
    @Test func theTraitIsConditional() throws {
        try #require(Self.source.count > 500)
        #expect(!Self.source.contains(".accessibilityAddTraits([.isSelected])"),
                "the trait is applied unconditionally, so every row announces as selected")
        #expect(!Self.source.contains(".accessibilityAddTraits(.isSelected)"),
                "the trait is applied unconditionally, so every row announces as selected")
    }
}
