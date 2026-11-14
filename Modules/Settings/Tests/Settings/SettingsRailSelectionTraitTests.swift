import Foundation
import Testing
@testable import Settings

/// The one non-colour carrier of which settings tab is open: `SettingsRail.railRow` adds
/// `.isSelected`. Without it every geometry test stays green while VoiceOver loses the only signal.
/// A source scan, because assertions against the live accessibility tree pass vacuously without an
/// assistive client attached.
@Suite struct SettingsRailSelectionTraitTests {

    @Test func theRailRowStillCarriesTheSelectedTrait() throws {
        let source = try settingsSource("SettingsLayout.swift", minLength: 500)
        try #require(source.contains("static func railRow("),
                     "railRow was renamed; this scan is no longer reading the rail's row")

        #expect(source.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"),
                "the rail's selected row no longer announces that it is selected — colour is then the only carrier, and colour is not audible")
        // The trait must not become unconditional: a row that always announces "selected" is as
        // useless as one that never does.
        #expect(!source.contains(".accessibilityAddTraits([.isSelected])"),
                "the trait is applied unconditionally, so every row announces as selected")
        #expect(!source.contains(".accessibilityAddTraits(.isSelected)"),
                "the trait is applied unconditionally, so every row announces as selected")
    }
}
