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
    /// `hue.accentColor` — measured, that drops NINE of the eleven named hues below 4.5:1 (only
    /// Indigo and Slate are dark enough raw), the worst being Cyan at 2.07:1.
    ///
    /// **`.none` is excluded on purpose, and the exclusion is load-bearing rather than tidy-up.**
    /// It takes the system accent untouched so that it draws exactly what macOS draws, which means
    /// it inherits Apple's contrast — 4.02:1 on the default blue, i.e. it would FAIL this bound.
    /// The way to satisfy this test for `.none` would be to deepen it, and deepening it is the
    /// thing that was tried and rejected: it makes "no accent" look unlike a stock control. If this
    /// loop is ever widened to all twelve, the fix is to narrow it again, not to change the tint.
    /// See `noneIsTheSystemAccentUntouched`.
    @Test func theTintCarriesTheWhiteLabelAppKitImposes() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let ratio = whiteContrast(srgb(SegmentedAccent.tint(for: hue)))
            #expect(ratio >= 4.5,
                    "AppKit will draw a white label on \(hue.rawValue)'s segment at only \(ratio):1")
        }
    }

    /// `.none` means "the stock macOS look", so it takes the system accent VERBATIM — not deepened
    /// like the eleven named hues, and certainly not a hardcoded blue.
    ///
    /// It was deepened at first, on uniformity grounds, and that was the wrong trade: it made the
    /// selection ~7% darker than a stock control, i.e. it changed the appearance of "no change".
    /// The accepted cost of handing the accent over untouched is that `.none` inherits Apple's own
    /// white-label contrast (4.02:1 on the default blue) — which is why
    /// `theTintCarriesTheWhiteLabelAppKitImposes` excludes it.
    ///
    /// Deliberately NOT written as "`.none` differs from the deepened accent". `AccentFill` only
    /// darkens what is too light, so on a Mac whose accent is already dark — Purple, Graphite — the
    /// deepening is a no-op and raw and deepened are the same colour. That assertion would pass
    /// here and fail on someone else's machine. The contract is "the system accent, untouched",
    /// and that is what is asserted; the separate check that named hues DO move uses Amber, a
    /// literal, so it means the same thing everywhere.
    @Test func noneIsTheSystemAccentUntouched() {
        #expect(srgb(SegmentedAccent.tint(for: .none)) == srgb(Color.accentColor),
                "`.none` must hand the system accent over verbatim, so it draws what macOS draws")
        // ...it is genuinely the system's, not the palette's own Blue...
        #expect(srgb(SegmentedAccent.tint(for: .none)) != srgb(SegmentedAccent.tint(for: .blue)))
        // ...and the exemption is `.none`'s alone: a named light hue is still deepened.
        #expect(srgb(SegmentedAccent.tint(for: .amber)) != srgb(LiquidGlassHue.amber.accentColor),
                "Amber is light enough to need deepening — only `.none` is exempt")
    }

    /// The tint must be colour and nothing else. A modifier that changed the control's metrics
    /// would reflow the Settings sheet, whose Appearance tab already fits its opening with single
    /// digits of slack — and the pane bar sheet's picker is inside a `.fixedSize()` footer row.
    ///
    /// The specimen must have a segment genuinely SELECTED. The selection is the part the tint
    /// actually colours — it is the `WindowPortal` lift — so a fixture whose `selection` matches no
    /// tag measures the one state in which the tint has nothing to do, and would be blind to a
    /// modifier that only disturbed the selected segment. (This test shipped that way: its tags
    /// were `rawValue.hashValue` against a `selection` of `1`, which matched nothing.)
    @MainActor
    @Test func tintingChangesNoMetrics() {
        struct Specimen: View {
            var hue: LiquidGlassHue?
            @State private var selection = FontSize.medium.percent
            var body: some View {
                Picker("Text size", selection: $selection) {
                    ForEach(FontSize.allCases) { size in
                        Text(size.displayName).tag(size.percent)
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
        var sites = 0
        for file in try Self.appSwiftSources() {
            // Collapse whitespace first, and ask the COLLAPSED text whether this file has a
            // segmented picker: a chain that happens to wrap as `.pickerStyle(\n.segmented)` is
            // invisible to the same question asked of the raw source, and would be skipped whole.
            let collapsed = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard collapsed.contains(".pickerStyle(.segmented)") else { continue }

            // One picker's modifier chain runs from its own `Picker(` to the next one, so
            // splitting there bounds each chain EXACTLY. The first draft counted characters
            // instead (a 220-char window), which is both fragile and wrong in the dangerous
            // direction: measured, the nearest following `Picker(` in SettingsView sits 201
            // characters away, so 19 more characters of caption would have let one picker's
            // window reach its neighbour's tint and report a missing tint as present.
            //
            // Splitting on `Picker(` also catches `DatePicker(`/`ColorPicker(`, which only adds
            // harmless extra boundaries — none of them can fall inside a segmented picker's chain.
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
                // ...and it has to be handed the LIVE hue. `.accentedSegments(.blue)` would tint
                // every picker blue for ever, which is the same bug wearing the fix's clothes and
                // is invisible to every other test here.
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
        // A tripwire, so the scan cannot pass by finding nothing. If you added a segmented picker
        // deliberately AND gave it `.accentedSegments`, raise this number.
        // 6 since Appearance's Text size stopped being a segmented picker: it is a preset row
        // over a slider now, and a `Button`'s tint is not the segmented-selection problem this
        // scan exists for. Row spacing, one control below it, is still segmented and still here.
        #expect(sites == 6, "expected 6 segmented pickers in the app, found \(sites)")
    }

    /// Every Swift file the SHIPPING app is built from: each module's `Sources`, plus `MacApp`.
    ///
    /// Both halves of this are corrections to the first draft, and both were latent rather than
    /// visible — the test passed with either bug present.
    ///
    /// `MacApp/` was not scanned at all. It is a sibling of `Modules/`, it is in no SPM package,
    /// and it is full of SwiftUI views — which makes it the single likeliest home for exactly the
    /// untinted seventh picker this test exists to catch.
    ///
    /// `.build/` WAS scanned. Walking `Modules/` for any path containing `/Sources/` swept in 553
    /// checked-out dependency files against 194 of ours. None of them happens to use a segmented
    /// picker today, so the count came out right by luck; one dependency shipping one would fail
    /// this test on third-party code. It also made the file set depend on whether the tree had
    /// been built.
    private static func appSwiftSources() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)      // …/Design/Tests/DesignTests/<this>.swift
            .deletingLastPathComponent()                // …/Design/Tests/DesignTests
            .deletingLastPathComponent()                // …/Design/Tests
            .deletingLastPathComponent()                // …/Modules/Design
            .deletingLastPathComponent()                // …/Modules
            .deletingLastPathComponent()                // …/<repo>

        let modules = repo.appendingPathComponent("Modules")
        var roots = [repo.appendingPathComponent("MacApp")]
        roots += try FileManager.default
            .contentsOfDirectory(at: modules, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Sources") }

        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let found = FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            files += found
        }
        // Nothing below a module's `Sources` or `MacApp` is a dependency, so no `.build` filter is
        // needed — but prove the roots resolved, or this returns [] and everything passes vacuously.
        #expect(files.count > 100, "found only \(files.count) app sources — the roots did not resolve")
        #expect(files.contains { $0.path.hasSuffix("MacApp/SyncCloudApp.swift") },
                "MacApp is not being scanned")
        #expect(!files.contains { $0.path.contains("/.build/") }, "a dependency source leaked in")
        return files
    }
}
