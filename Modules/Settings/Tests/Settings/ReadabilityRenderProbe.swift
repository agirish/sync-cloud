import Testing
import SwiftUI
import AppKit
@testable import Settings
@testable import Design

/// Appearance ▸ Text & Spacing rendered in the states that matter, with the assertions geometry
/// can make. A preview that ignored its settings would pass every fit test; what it wouldn't do is
/// change when the settings do.
@Suite struct ReadabilityRenderProbe {

    @MainActor
    private func laidOut(_ size: FontSize, _ density: ListDensity, name: String,
                         appearance: NSAppearance.Name = .aqua) -> CGFloat {
        let defaults = ScratchDefaults("ReadabilityProbe.\(name)")
        defaults.set(size.percent, forKey: FontSize.defaultsKey)
        defaults.set(density.rawValue, forKey: ListDensity.defaultsKey)

        let host = NSHostingView(rootView:
            ReadabilitySettingsTab()
                .defaultAppStorage(defaults)
                .appFontSize(size)
                .frame(width: 547)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let height = host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: 579, height: height + 32)
        host.layoutSubtreeIfNeeded()
        return height
    }

    /// The preview really follows the row spacing. Compact drops the size-and-date line, shrinks the
    /// icon and cuts the padding, so the tab must get shorter; a static preview wouldn't.
    @MainActor
    @Test func theTabShortensWhenRowSpacingTightens() {
        let comfortable = laidOut(.medium, .comfortable, name: "default")
        let compact = laidOut(.medium, .compact, name: "compact")

        #expect(comfortable > 0 && compact > 0, "a state laid out to nothing")
        #expect(compact < comfortable,
                """
                The tab is \(compact)pt at Compact against \(comfortable)pt at Comfortable — the \
                preview is not following the row spacing it claims to show.
                """)
    }

    /// Both appearances lay out, at the same height. The tab's accent, `.secondary` and window
    /// colours all resolve per appearance, and a border lost in a dark ground is invisible to any
    /// measurement here.
    @MainActor
    @Test func theTabDrawsInBothAppearances() {
        let light = laidOut(.medium, .comfortable, name: "light", appearance: .aqua)
        let dark = laidOut(.medium, .comfortable, name: "dark", appearance: .darkAqua)

        #expect(light > 0 && dark > 0, "an appearance laid out to nothing")
        // Height doesn't depend on appearance, so this asserts neither collapses.
        #expect(abs(light - dark) < 1,
                """
                The tab lays out at \(light)pt light and \(dark)pt dark — appearance is moving \
                geometry, which nothing here intends.
                """)
    }

    /// And it follows the text size.
    @MainActor
    @Test func theTabGrowsWithTheTextSize() {
        let standard = laidOut(.medium, .comfortable, name: "standard")
        let largest = laidOut(.extraLarge, .comfortable, name: "largest")

        #expect(largest > standard,
                """
                The tab is \(largest)pt at \(FontSize.extraLarge.percent)% against \(standard)pt at \
                100% — nothing on it is following the text size.
                """)
    }
}
