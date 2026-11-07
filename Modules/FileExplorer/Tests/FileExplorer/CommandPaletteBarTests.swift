import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The toolbar's ⌘K pill, rendered and read back in light and dark.
///
/// The claim that matters is about pixels: the key is drawn at rest, unlike every other badged
/// control, which shows its chord only under the ⌥-hold reveal. A `.shortcutKeycap(_:)` applied by
/// mistake would pass every structural check and draw nothing until a modifier went down.
///
/// Widths are checked against `CommandPaletteBarMetrics`, which the toolbar's shedding ladder
/// spends: under-measuring folds the whole row behind macOS's overflow chevron, with no error.
///
/// `.machinePinned(.pixelSampling)`: it reads pixels out of a live renderer.
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

    /// The painted width in points, not pixels, to match `CommandPaletteBarMetrics`. The scale
    /// comes from the rep rather than a constant, so a 1× display reads correctly too.
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

    /// The whole point of the control. Rendered with no reveal active, so a pill built on
    /// `.shortcutKeycap(_:)` comes back with no key. Measured against the arithmetic for a pill with
    /// no keycap: the drawn key adds a keycap's width. Not compared against `chord: ""`, because
    /// `ShortcutKeycap("")` draws an empty capsule and the two would differ only by the glyph.
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
        // ...and it shed the word, not the key: still wide enough for a magnifier and a keycap.
        #expect(Self.inkWidth(compact) > 55,
                "the compact pill collapsed past a magnifier and a key in \(scheme) — it has shed the chord")
    }

    /// The rendered widths match the arithmetic the toolbar spends. `WorkspaceBarMetrics.styles`
    /// adds these to the workspace bar's to decide what fits; under-measuring by a few points folds
    /// the whole toolbar behind macOS's overflow chevron, with no error.
    @Test(arguments: [CommandPaletteBarStyle.full, .compact])
    func theArithmeticMatchesWhatIsDrawn(style: CommandPaletteBarStyle) {
        let predicted = CommandPaletteBarMetrics.width(
            style: style,
            labelWidth: CommandPaletteBarMetrics.labelWidth(CommandPaletteBar.label, scale: 1),
            keycapWidth: CommandPaletteBarMetrics.keycapWidth(symbol: "⌘K", scale: 1))
        let drawn = CGFloat(Self.inkWidth(Self.render(style, scheme: .light)))
        #expect(abs(drawn - predicted) <= 20,
                "the \(style) pill draws \(drawn)pt against \(predicted)pt of arithmetic — the toolbar is reserving the wrong amount of room for it")
        // **Never** under-measure, the direction with no symptom until the row overflows. The
        // tolerance above is loose in the safe direction; this one is tight in the unsafe one.
        #expect(predicted >= drawn,
                "the arithmetic under-measures the \(style) pill by \(drawn - predicted)pt, which is how the toolbar overflows")
    }
}
