import Foundation
import Testing
@testable import FileExplorer

/// What VoiceOver reads for a tab chip. `ProviderLogo` is hidden from VoiceOver, and on a chip the
/// mark is the only thing telling two same-named tabs apart, so the chip's label carries the
/// source's name instead.
@Suite struct PaneTabStripSpokenNameTests {

    private func item(_ title: String, source: String?) -> PaneTabStrip.Item {
        PaneTabStrip.Item(id: UUID(), title: title, markImageName: "icloud", isActive: false,
                          fullPath: "/x/\(title)", sourceName: source)
    }

    /// Two "Documents" chips from different clouds sound different.
    @Test func twoSameNamedChipsFromDifferentSourcesSoundDifferent() {
        let iCloud = PaneTabStrip.spokenName(item("Documents", source: "iCloud Drive"))
        let oneDrive = PaneTabStrip.spokenName(item("Documents", source: "OneDrive"))
        #expect(iCloud == "Documents, iCloud Drive")
        #expect(oneDrive == "Documents, OneDrive")
    }

    /// Nothing is said twice: a root tab is titled with the source's name, and a colliding title is
    /// already qualified with it.
    @Test func aTitleThatAlreadyNamesTheSourceIsReadAsItIs() {
        #expect(PaneTabStrip.spokenName(item("iCloud Drive", source: "iCloud Drive")) == "iCloud Drive")
        #expect(PaneTabStrip.spokenName(item("Documents — iCloud Drive", source: "iCloud Drive"))
                == "Documents — iCloud Drive")
    }

    /// A source that is gone has no name to add.
    @Test func aChipWithNoSourceIsReadByItsTitle() {
        #expect(PaneTabStrip.spokenName(item("Documents", source: nil)) == "Documents")
        #expect(PaneTabStrip.spokenName(item("Documents", source: "")) == "Documents")
    }

    /// **The call sites.** SwiftUI builds no accessibility tree under `swift test`, so the label
    /// cannot be read back from a render; the source is read instead. Both chips that draw a title
    /// — the full chip and the overflow rung's menu chip — must label it with `spokenName`.
    @Test func bothChipTitlesAreLabelledWithTheSpokenName() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/PaneTabStrip.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for subject in ["item", "active"] {
            let title = try #require(source.range(of: "Text(\(subject).title)"),
                                     "no Text(\(subject).title) in the strip")
            let after = source[title.upperBound...].prefix(300)
            #expect(after.contains(".accessibilityLabel(Self.spokenName(\(subject)))"),
                    "Text(\(subject).title) is not labelled with spokenName")
        }
    }
}
