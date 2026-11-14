import AppKit
import SwiftUI
import Testing
@testable import Design

/// `SegmentedAccent`: what a `.segmented` picker's selection is tinted with, and that every
/// segmented picker in the app asks for it.
///
/// These tests can't read the selected segment's pixels: on macOS 26 the selection is a
/// `LiftPortalView` the window server composites, so it renders only on screen in the frontmost
/// app, never offscreen. This pins the colour choice, metric neutrality and call-site coverage.
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

    /// A prominent button deepens every hue, `.none` included: it carries an app verb in white
    /// beside lit tools that already deepen the Mac's accent, so at `.none` it is the deepened
    /// system accent, not the stock 4.02:1 a segmented picker keeps.
    @Test func aProminentButtonCarriesItsWhiteLabelOnEveryHue() {
        for hue in LiquidGlassHue.allCases {
            let ratio = whiteContrast(srgb(ProminentAccent.tint(for: hue)))
            #expect(ratio >= 4.5, "a prominent button's white label on \(hue.rawValue) is only \(ratio):1")
        }
        #expect(srgb(ProminentAccent.tint(for: .none)) == srgb(LiquidGlassHue.none.accentFillColor))
        // By component, as `noneIsTheSystemAccentUntouched` compares: an `NSColor` inequality also
        // holds for one colour with and without HDR headroom metadata, so it could not fail.
        let prominent = srgb(ProminentAccent.tint(for: .none)), system = srgb(Color.accentColor)
        #expect(abs(prominent.redComponent - system.redComponent) > 0.01
                || abs(prominent.greenComponent - system.greenComponent) > 0.01
                || abs(prominent.blueComponent - system.blueComponent) > 0.01,
                "at None a prominent button is the stock accent, a second blue beside the deepened lit tools")
    }

    /// AppKit draws the selected segment's label white on every fill, so the tint is the deepened
    /// fill. Must fail if `SegmentedAccent.tint(for:)` becomes `hue.accentColor`. `.none` is excluded
    /// on purpose: it keeps the system accent untouched (`noneIsTheSystemAccentUntouched`).
    @Test func theTintCarriesTheWhiteLabelAppKitImposes() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let ratio = whiteContrast(srgb(SegmentedAccent.tint(for: hue)))
            #expect(ratio >= 4.5,
                    "AppKit will draw a white label on \(hue.rawValue)'s segment at only \(ratio):1")
        }
    }

    /// `.none` means "the stock macOS look", so it takes the system accent verbatim: not deepened,
    /// and not a hardcoded blue. Not written as "differs from the deepened accent": on a Mac with a
    /// dark accent (Purple, Graphite) `AccentFill` leaves it alone and the two are the same colour.
    @Test func noneIsTheSystemAccentUntouched() {
        // Compared by component, to float precision: `.none` reads AppKit's accent (so a window
        // root's accent can't recolour it), and SwiftUI's copy of that colour carries HDR headroom
        // metadata and single-precision components that make the two `NSColor`s unequal.
        let none = srgb(SegmentedAccent.tint(for: .none)), system = srgb(Color.accentColor)
        #expect(abs(none.redComponent - system.redComponent) < 0.001
                && abs(none.greenComponent - system.greenComponent) < 0.001
                && abs(none.blueComponent - system.blueComponent) < 0.001,
                "`.none` must hand the system accent over verbatim, so it draws what macOS draws")
        // ...it is genuinely the system's, not the palette's own Blue...
        #expect(srgb(SegmentedAccent.tint(for: .none)) != srgb(SegmentedAccent.tint(for: .blue)))
        // ...and the exemption is `.none`'s alone: a named light hue is still deepened.
        #expect(srgb(SegmentedAccent.tint(for: .amber)) != srgb(LiquidGlassHue.amber.accentColor),
                "Amber is light enough to need deepening — only `.none` is exempt")
    }

    /// The tint must be colour and nothing else: changed metrics would reflow the Settings sheet,
    /// which fits with single digits of slack. The specimen has a segment selected, since the
    /// selection is what the tint colours.
    @MainActor
    @Test func tintingChangesNoMetrics() {
        struct Specimen: View {
            var hue: LiquidGlassHue?
            @State private var selection = FontSize.medium.percent
            var body: some View {
                Picker("Text size", selection: $selection) {
                    ForEach(FontSize.allCases) { size in
                        Text("\(size.percent)%").tag(size.percent)
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

        // The premise the fixture depends on: the specimen's selection names a tag that exists.
        #expect(FontSize.allCases.contains { $0.percent == FontSize.medium.percent },
                "the specimen selects a tag no segment carries — nothing is selected")

        let bare = size(nil)
        #expect(bare.width > 0 && bare.height > 0, "the specimen laid out to nothing")
        for hue in LiquidGlassHue.allCases {
            #expect(size(hue) == bare, "\(hue.rawValue) changed the picker's metrics")
        }
    }

    /// Every `.segmented` picker in the app asks for the app's accent, so a new one can't sit in
    /// system blue. A source scan, because the offscreen renderer can't see a selection and a
    /// SwiftUI tree can't be asked its tint.
    @Test func everySegmentedPickerInTheAppTakesTheAppAccent() throws {
        var sites = 0
        for file in try AccentFillScanTests.appSources() {
            // Ask the collapsed text, so a chain that wraps as `.pickerStyle(\n.segmented)` isn't
            // skipped.
            let collapsed = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard collapsed.contains(".pickerStyle(.segmented)") else { continue }

            // Split at each `Picker(` to bound each chain exactly: a character window could reach
            // a neighbour's tint and report a missing one as present.
            for chunk in collapsed.components(separatedBy: "Picker(")
            where chunk.contains(".pickerStyle(.segmented)") {
                sites += 1
                let site = "\(file.lastPathComponent): \(String(chunk.prefix(90)))"
                guard let argRange = chunk.range(of: ".accentedSegments(") else {
                    Issue.record("""
                        A `.segmented` picker in \(site) does not call `.accentedSegments(hue)`, \
                        so its selection will paint the SYSTEM accent while the rest of the window \
                        follows the app's.
                        """)
                    continue
                }
                // ...and it must be handed the live hue: `.accentedSegments(.blue)` would tint the
                // picker blue whatever the user picks, and no other test here would see it.
                let argument = chunk[argRange.upperBound...].prefix { $0 != ")" }
                    .trimmingCharacters(in: .whitespaces)
                #expect(!argument.hasPrefix("."),
                        """
                        A `.segmented` picker in \(site) passes the hue LITERAL \
                        `\(argument)` to `.accentedSegments`, so it will ignore the accent the \
                        user picks. Pass the selected hue.
                        """)
            }
        }
        // A tripwire, so the scan can't pass by finding nothing.
        #expect(sites >= 20, "expected at least 20 segmented pickers in the app, found \(sites)")
    }
}
