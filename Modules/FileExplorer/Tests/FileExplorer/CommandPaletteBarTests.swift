import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The toolbar's ⌘K pill, **rendered and read back**, in light and dark.
///
/// The one claim that matters here cannot be made any other way: **the key is drawn at rest.** That
/// is the entire reason this control exists — every other badged control in the app shows its chord
/// only under the ⌥-hold reveal, which teaches it to nobody who is not already holding ⌥ — and it
/// is a claim about pixels. A `.shortcutKeycap(_:)` applied by mistake would satisfy every
/// structural check and render nothing until a modifier key went down.
///
/// The widths are asserted against `CommandPaletteBarMetrics`, which the toolbar's shedding ladder
/// spends: an arithmetic that under-measures this control folds the whole row behind macOS's
/// overflow chevron, with no error and no visual cue.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels out of a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct CommandPaletteBarTests {

    static func render(_ style: CommandPaletteBarStyle, scheme: ColorScheme,
                       width: CGFloat = 320, height: CGFloat = 40) -> NSBitmapImageRep {
        let subject = CommandPaletteBar(style: style, chord: "⌘K", action: {})
            .frame(width: width, height: height, alignment: .leading)
            // RGB, never `Color(white:)`: a greyscale backdrop makes the whole cached bitmap
            // greyscale and every colour reading comes back as zero.
            .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13)
                                        : Color(red: 0.95, green: 0.95, blue: 0.96))
            .environment(\.colorScheme, scheme)
            // Materials desaturate in a window that is not key, and a borderless test window never
            // is. The app pins this on its own window for the same reason.
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Columns carrying anything other than the image's own corner — the pill's painted footprint.
    static func inkedColumns(_ rep: NSBitmapImageRep) -> Set<Int> {
        guard let background = rep.colorAt(x: 1, y: 1) else { return [] }
        var columns = Set<Int>()
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - background.redComponent),
                       max(abs(c.greenComponent - background.greenComponent),
                           abs(c.blueComponent - background.blueComponent))) > 0.02 {
                    columns.insert(x)
                    break
                }
            }
        }
        return columns
    }

    /// The painted width **in points**, not pixels.
    ///
    /// The bitmap is 2× on this display and `CommandPaletteBarMetrics` is in points — comparing the
    /// two directly is how the arithmetic looked twice as wrong as it was. The scale comes from the
    /// rep itself rather than a constant, so a 1× display reads correctly too.
    static func inkWidth(_ rep: NSBitmapImageRep, hostWidth: CGFloat = 320) -> CGFloat {
        let cols = inkedColumns(rep)
        guard let lo = cols.min(), let hi = cols.max() else { return 0 }
        let scale = CGFloat(rep.pixelsWide) / hostWidth
        return CGFloat(hi - lo + 1) / scale
    }

    static func pixelsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard let da = a.tiffRepresentation, let db = b.tiffRepresentation else { return false }
        return da == db
    }

    // MARK: The key is on screen without anyone holding a modifier

    /// **The whole point of the control.**
    ///
    /// Rendered with no reveal active — `shortcutRevealActive` defaults to false — so a pill built
    /// on `.shortcutKeycap(_:)` instead of an inline key comes back with no key at all. Measured
    /// against the arithmetic for a pill *carrying no keycap*: with the key drawn the compact rung
    /// is a keycap's width wider than that, and with the key hidden behind a modifier it would land
    /// on it almost exactly.
    ///
    /// An earlier version of this compared against `CommandPaletteBar(chord: "")` and was nearly
    /// useless: `ShortcutKeycap("")` draws an empty capsule, not nothing, so the two differed by
    /// only the glyph — the same blank-capsule trap `.shortcutKeycap`'s own `nil` handling exists
    /// to avoid, met from the other side.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theKeyIsDrawnWithNoModifierHeld(scheme: ColorScheme) {
        let drawn = Self.inkWidth(Self.render(.compact, scheme: scheme))
        let withoutAnyKey = CommandPaletteBarMetrics.width(style: .compact, labelWidth: 0,
                                                           keycapWidth: 0)
        let keycap = CommandPaletteBarMetrics.keycapWidth(symbol: "⌘K", scale: 1)
        #expect(drawn > withoutAnyKey + keycap * 0.6,
                "the compact pill draws \(drawn)pt against \(withoutAnyKey)pt of pill and \(keycap)pt of key in \(scheme) — the ⌘K key is not painted at rest, which is the one thing this control exists for")
    }

    /// Two different chords render differently — the key is really the string it is given, not a
    /// fixed glyph. The discriminating form, because a clipped or missing key compares equal to
    /// itself and passes anything weaker.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theKeyShowsTheChordItWasGiven(scheme: ColorScheme) {
        func render(_ chord: String) -> NSBitmapImageRep {
            let subject = CommandPaletteBar(style: .compact, chord: chord, action: {})
                .frame(width: 320, height: 40, alignment: .leading)
                .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13)
                                            : Color(red: 0.95, green: 0.95, blue: 0.96))
                .environment(\.colorScheme, scheme)
                .environment(\.controlActiveState, .active)
            let host = NSHostingView(rootView: AnyView(subject))
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 40)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.colorSpace = .sRGB
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        #expect(!Self.pixelsEqual(render("⌘K"), render("⇧⌘P")),
                "two different chords rendered identically in \(scheme) — the key is a fixed glyph")
    }

    // MARK: The two rungs are two different controls, and the arithmetic knows their widths

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theCompactRungIsNarrowerAndStillCarriesTheKey(scheme: ColorScheme) {
        let full = Self.render(.full, scheme: scheme)
        let compact = Self.render(.compact, scheme: scheme)
        #expect(Self.inkWidth(compact) < Self.inkWidth(full),
                "the compact pill is not narrower than the full one in \(scheme) — the word is not being shed")
        // ...and it is the WORD that went, not the key: the compact pill is still wide enough to
        // hold a magnifier and a keycap. A rung that had dropped the key would collapse further.
        #expect(Self.inkWidth(compact) > 55,
                "the compact pill collapsed past a magnifier and a key in \(scheme) — it has shed the chord")
    }

    /// **The rendered widths match the arithmetic the toolbar spends.**
    ///
    /// This is the load-bearing one for the row: `WorkspaceBarMetrics.styles` adds these numbers to
    /// the workspace bar's and decides what fits. An arithmetic that under-measures the pill by a
    /// few points is exactly the failure that has no symptom short of the whole toolbar folding
    /// behind macOS's overflow chevron — no error, no cue, the control simply gone.
    @Test(arguments: [CommandPaletteBarStyle.full, .compact])
    func theArithmeticMatchesWhatIsDrawn(style: CommandPaletteBarStyle) {
        let predicted = CommandPaletteBarMetrics.width(
            style: style,
            labelWidth: CommandPaletteBarMetrics.labelWidth(CommandPaletteBar.label, scale: 1),
            keycapWidth: CommandPaletteBarMetrics.keycapWidth(symbol: "⌘K", scale: 1))
        let drawn = CGFloat(Self.inkWidth(Self.render(style, scheme: .light)))
        #expect(abs(drawn - predicted) <= 20,
                "the \(style) pill draws \(drawn)pt against \(predicted)pt of arithmetic — the toolbar is reserving the wrong amount of room for it")
        // **Never UNDER-measure**, which is the direction with no symptom short of the whole row
        // disappearing behind macOS's overflow chevron. The tolerance above is deliberately loose
        // in the safe direction and this is tight in the unsafe one.
        #expect(predicted >= drawn,
                "the arithmetic under-measures the \(style) pill by \(drawn - predicted)pt, which is how the toolbar overflows")
    }
}
