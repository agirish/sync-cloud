import AppKit
import SwiftUI
import Testing
@testable import Design

/// `SegmentedAccent` — what a `.segmented` picker's selection is tinted with, and that every
/// segmented picker in the app actually asks for it.
///
/// What these tests deliberately do NOT do is read the selected segment's pixels. On macOS 26
/// that selection is a `LiftPortalView` inside a `WindowPortal`: the window server composites it,
/// so it contributes ZERO pixels to any offscreen bitmap — measured, on the host view and on every
/// subview down to the portal's own hosting view, for the tinted and the untinted control alike.
/// It renders only on screen, in a window belonging to the frontmost app, which is not something a
/// test can arrange without stealing focus and a screen-recording grant. The paint itself was
/// therefore verified by screen capture in both appearances (see `SegmentedAccent`'s own comment);
/// what is pinned here is the colour CHOICE, the metric-neutrality, and the call-site coverage —
/// the three things that can go wrong silently.
@Suite struct SegmentedAccentTests {

    private func srgb(_ color: Color) -> NSColor {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            Issue.record("\(color) has no sRGB representation")
            return .white
        }
        return converted
    }

    private func whiteContrast(_ fill: NSColor) -> CGFloat {
        let l = AccentLabel.relativeLuminance(red: fill.redComponent,
                                              green: fill.greenComponent,
                                              blue: fill.blueComponent)
        return 1.05 / (l + 0.05)
    }

    /// The reason the tint is the DEEPENED fill and not the raw accent.
    ///
    /// AppKit draws the selected segment's label itself, and it draws it WHITE on every fill —
    /// including one far too light to carry white. Captured on screen: raw Amber renders white at
    /// 2.24:1 and raw Cyan at 2.07:1, both unreadable. Since the label colour is imposed, the fill
    /// has to earn it, which is exactly what `accentFillColor` guarantees.
    ///
    /// This is the assertion that fails if someone "simplifies" `SegmentedAccent.tint(for:)` to
    /// `hue.accentColor` — six of the twelve hues drop below 4.5:1.
    @Test func theTintCarriesTheWhiteLabelAppKitImposes() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let ratio = whiteContrast(srgb(SegmentedAccent.tint(for: hue)))
            #expect(ratio >= 4.5,
                    "AppKit will draw a white label on \(hue.rawValue)'s segment at only \(ratio):1")
        }
    }

    /// `.none` means "follow the system accent", and it has to keep meaning that here: the stock
    /// macOS look is a real choice in the picker, not a gap to be patched over with a literal blue.
    /// Pinned as the deepened SYSTEM accent — deepened for the same white-label reason as every
    /// other hue, and system rather than hardcoded so it still tracks the user's macOS setting.
    @Test func noneFollowsTheSystemAccentRatherThanALiteral() {
        #expect(srgb(SegmentedAccent.tint(for: .none)) == srgb(AccentFill.deepened(Color.accentColor)))
        // ...and it is genuinely the system's, not the palette's own Blue.
        #expect(srgb(SegmentedAccent.tint(for: .none)) != srgb(SegmentedAccent.tint(for: .blue)))
    }

    /// The tint must be colour and nothing else. A modifier that changed the control's metrics
    /// would reflow the Settings sheet, whose Appearance tab already fits its opening with single
    /// digits of slack — and the pane bar sheet's picker is inside a `.fixedSize()` footer row.
    @MainActor
    @Test func tintingChangesNoMetrics() {
        struct Specimen: View {
            var hue: LiquidGlassHue?
            @State private var selection = 1
            var body: some View {
                Picker("Text size", selection: $selection) {
                    ForEach(FontSize.allCases) { size in
                        Text(size.displayName).tag(size.rawValue.hashValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .modifier(MaybeAccented(hue: hue))
            }
        }
        struct MaybeAccented: ViewModifier {
            var hue: LiquidGlassHue?
            @ViewBuilder func body(content: Content) -> some View {
                if let hue { content.accentedSegments(hue) } else { content }
            }
        }
        func size(_ hue: LiquidGlassHue?) -> CGSize {
            let host = NSHostingView(rootView: Specimen(hue: hue))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }

        let bare = size(nil)
        #expect(bare.width > 0 && bare.height > 0, "the specimen laid out to nothing")
        for hue in LiquidGlassHue.allCases {
            #expect(size(hue) == bare, "\(hue.rawValue) changed the picker's metrics")
        }
    }

    /// Every `.segmented` picker in the app asks for the app's accent.
    ///
    /// The coverage test, and the one that earns `accentedSegments` its existence as a named
    /// modifier: the failure mode this guards is not a wrong colour but a SEVENTH picker added
    /// later without the tint, sitting in system blue beside five that follow the hue. Nothing
    /// else would catch that — the offscreen renderer cannot see any of their selections.
    ///
    /// Scans sources rather than views because a SwiftUI tree cannot be asked what tint it carries;
    /// `SettingsSearchTests.controlLabelsInTabSources` reads sources for the same reason.
    @Test func everySegmentedPickerInTheAppTakesTheAppAccent() throws {
        let modules = URL(fileURLWithPath: #filePath)   // …/Design/Tests/DesignTests/<this>.swift
            .deletingLastPathComponent()                // …/Design/Tests/DesignTests
            .deletingLastPathComponent()                // …/Design/Tests
            .deletingLastPathComponent()                // …/Modules/Design
            .deletingLastPathComponent()                // …/Modules

        let swiftFiles = FileManager.default
            .enumerator(at: modules, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.path.contains("/Sources/") } ?? []
        #expect(!swiftFiles.isEmpty, "found no module sources under \(modules.path)")

        var sites = 0
        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(".pickerStyle(.segmented)") else { continue }
            // Collapse whitespace so the scan is not defeated by where the chain wraps.
            let collapsed = source.replacingOccurrences(of: #"\s+"#, with: " ",
                                                        options: .regularExpression)
            let chains = collapsed.components(separatedBy: ".pickerStyle(.segmented)").dropFirst()
            for chain in chains {
                sites += 1
                // The tint has to be on the picker's own chain: the next few modifiers, before
                // anything that could close the expression.
                let window = String(chain.prefix(220))
                #expect(window.contains(".accentedSegments("),
                        """
                        A `.segmented` picker in \(file.lastPathComponent) does not call \
                        `.accentedSegments(hue)`, so its selection will paint the SYSTEM accent \
                        while the rest of the window follows the app's. Chain was: \(window)
                        """)
            }
        }
        // A count, so the scan cannot pass by finding nothing — the six the app ships today.
        #expect(sites == 6, "expected 6 segmented pickers in the app, found \(sites)")
    }
}
