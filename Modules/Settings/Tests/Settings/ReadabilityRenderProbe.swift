import Testing
import SwiftUI
import AppKit
@testable import Settings
@testable import Design

/// The Readability tab rendered in the states that matter, with the assertions geometry can make
/// about it — and a PNG per state when `READ_PROBE_DIR` is set, so a person can look.
///
/// A tab whose preview ignored its settings would lay out at exactly the right size, in the right
/// place, with every fit test green. What it would not do is change when the settings do.
@Suite struct ReadabilityRenderProbe {

    @MainActor
    private func laidOut(_ size: FontSize, _ density: ListDensity, name: String,
                         appearance: NSAppearance.Name = .aqua) -> CGFloat {
        let suite = "ReadabilityProbe.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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

        if let dir = ProcessInfo.processInfo.environment["READ_PROBE_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("readability-\(name).png"))
            }
        }
        return height
    }

    /// The preview really is showing the row spacing, not a picture of one.
    ///
    /// Compact drops the size-and-date line, shrinks the icon and cuts the padding, so the tab
    /// itself has to get measurably shorter. If the preview were static this difference would be
    /// zero and nothing else in the suite would notice.
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

    /// **Both appearances draw**, and draw differently.
    ///
    /// The tab leans on `Color.accentColor.opacity(0.10)` for a selected tile, `.secondary`
    /// opacities for the tile borders and the preview's ground, and `.windowBackgroundColor`
    /// behind all of it — every one of which resolves per appearance. A tile border that vanished
    /// into a dark ground, or a preview panel that stopped being distinguishable from the page,
    /// would be invisible to every measurement on this tab, which is why this renders both and
    /// writes them out to be looked at.
    @MainActor
    @Test func theTabDrawsInBothAppearances() {
        let light = laidOut(.medium, .comfortable, name: "light", appearance: .aqua)
        let dark = laidOut(.medium, .comfortable, name: "dark", appearance: .darkAqua)

        #expect(light > 0 && dark > 0, "an appearance laid out to nothing")
        // Height is appearance-independent; what this asserts is that neither collapses. The
        // colours are judged from the PNGs the two calls above write.
        #expect(abs(light - dark) < 1,
                """
                The tab lays out at \(light)pt light and \(dark)pt dark — appearance is moving \
                geometry, which nothing here intends.
                """)
    }

    /// And it follows the text size, which is the other half of the same claim.
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
