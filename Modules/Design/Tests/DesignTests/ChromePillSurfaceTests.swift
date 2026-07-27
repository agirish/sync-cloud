import AppKit
import SwiftUI
import Testing
@testable import Design

/// `chromePillSurface` is the ground under the pane header's provider capsule. It swaps the
/// MATERIAL beneath the pill and must change nothing else: the capsule sits in a `ViewThatFits`
/// ladder whose rungs are chosen by ideal width, inside a header pinned to
/// `LiquidGlass.headerHeight`. A background that added even a point would silently pick a
/// different rung — dropping the provider logo at a width that used to keep it — or break the
/// 83.5 line the pane header and `LensHeaderCard` share.
///
/// Measured laid-out, not asserted from the source, and for a specific reason: on macOS 26 the
/// `.clear` branch is `.glassEffect`, whose painted size has come apart from its frame in this
/// codebase before — `PaneNavChrome`'s comment records three rounds of hover fixes lost to
/// exactly that. This pins the metrics only; whether the frost actually PAINTS is not something
/// an offscreen host can answer (glass renders nothing there), and was checked in the app.
///
/// The levels are looped rather than passed as `@Test(arguments:)` because `GlassLevel` is not
/// `Sendable`, and widening a production type to satisfy a test is the wrong direction.
@MainActor
@Suite(.serialized) struct ChromePillSurfaceTests {

    private static let wash = Color.blue.opacity(0.12)

    /// The capsule's real content — a 28pt logo box, the semibold provider name, the menu
    /// chevron — at the padding `providerCapsule` applies, so the measurement is of the pill
    /// that ships rather than of a bare rectangle.
    private func pill(_ name: String = "OneDrive (Personal)") -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 28, height: 28)
            Text(name).font(.headline.weight(.semibold))
            Image(systemName: "chevron.down").font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    /// Dressing the pill costs it nothing at any level. `.clear` is the case that matters — it is
    /// the one that stops being a plain `.background` — but a regression in the untouched branches
    /// would be just as invisible, so all three are pinned.
    @Test func groundIsLayoutNeutralAtEveryLevel() {
        let bare = size(pill())
        for level in GlassLevel.allCases {
            #expect(size(pill().chromePillSurface(level, wash: Self.wash)) == bare,
                    "\(level.rawValue) changed the pill's metrics")
        }
    }

    /// ...and the levels agree with each other, so switching glass in Settings never reflows the
    /// header. Implied by the above, but this is the property the header actually depends on: the
    /// ladder is stable only if every level measures the same, not merely if each matches its own
    /// bare pill.
    @Test func everyLevelMeasuresTheSame() {
        let sizes = Set(GlassLevel.allCases.map { size(pill().chromePillSurface($0, wash: Self.wash)) })
        #expect(sizes.count == 1)
    }

    /// The ground tracks its content rather than fixing a width — otherwise a long provider name
    /// would be trimmed by the background instead of by the truncation the header ladder intends.
    @Test func groundTracksContentWidth() {
        let short = size(pill().chromePillSurface(.clear, wash: Self.wash))
        let long = size(pill("Marketing Team Shared Archive Drive")
            .chromePillSurface(.clear, wash: Self.wash))
        #expect(long.width > short.width)
        #expect(long.height == short.height)
    }

    // MARK: The ground paints

    /// The assertion `29d0cc7` could not make. Its ground was `.glassEffect`, which renders
    /// nothing into an offscreen bitmap, so "does the pill have a ground at all" was answerable
    /// only from a screenshot — and the answer, once seen, was "yes, and far too dark". A
    /// self-drawn film shows up in a bitmap, so the property is pinned here instead.
    ///
    /// Sampled in the capsule's left cap, which is ground and nothing else: the pill's content
    /// starts 8pt in and its first 28pt are a transparent logo box.
    @Test func clearLiftsTheGroundInDark() {
        let backdrop = Color(white: 0.30)
        let clear = groundLuminance(.clear, over: backdrop, appearance: .darkAqua)
        let frosted = groundLuminance(.frosted, over: backdrop, appearance: .darkAqua)
        #expect(clear > frosted, "Clear's ground must lift off the surface, not sink into it")
    }

    /// The mirror image: `.primary` settles on a light appearance, so the same film separates the
    /// pill by going *down* against a light surface rather than up.
    @Test func clearSettlesTheGroundInLight() {
        let backdrop = Color(white: 0.80)
        let clear = groundLuminance(.clear, over: backdrop, appearance: .aqua)
        let frosted = groundLuminance(.frosted, over: backdrop, appearance: .aqua)
        #expect(clear < frosted, "Clear's ground must separate on a light appearance too")
    }

    /// Every other level leaves the surface exactly as the wash alone would — the ground is
    /// Clear's alone, not a change to how the capsule looks at Frosted or Solid.
    @Test func otherLevelsAddNoGround() {
        let backdrop = Color(white: 0.30)
        let bare = groundLuminance(nil, over: backdrop, appearance: .darkAqua)
        for level in GlassLevel.allCases where !level.needsChromeFrosting {
            #expect(abs(groundLuminance(level, over: backdrop, appearance: .darkAqua) - bare) < 0.01,
                    "\(level.rawValue) should paint the wash and nothing more")
        }
    }

    /// Renders the pill over a known backdrop and reads the capsule's left cap. `nil` level draws
    /// the wash directly, i.e. what every non-Clear level is supposed to reduce to.
    private func groundLuminance(_ level: GlassLevel?, over backdrop: Color,
                                 appearance: NSAppearance.Name) -> Double {
        let dressed = level.map { AnyView(pill().chromePillSurface($0, wash: Self.wash)) }
            ?? AnyView(pill().background(Self.wash, in: Capsule()))
        let scene = ZStack { backdrop; dressed }.frame(width: 260, height: 60)
        let host = NSHostingView(rootView: AnyView(scene))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return .nan }
        host.cacheDisplay(in: host.bounds, to: rep)
        // The pill is centred in the 260x60 scene; step 4pt in from its left edge, at mid-height.
        let scale = Double(rep.pixelsWide) / 260.0
        let pillWidth = Double(size(pill().chromePillSurface(.clear, wash: Self.wash)).width)
        let x = Int(((260.0 - pillWidth) / 2.0 + 4.0) * scale)
        let y = Int(30.0 * scale)
        guard let px = rep.colorAt(x: x, y: y) else { return .nan }
        return 0.2126 * Double(px.redComponent) + 0.7152 * Double(px.greenComponent)
             + 0.0722 * Double(px.blueComponent)
    }

    /// Unconstrained: the pill's own ideal size is what the `ViewThatFits` ladder compares, so a
    /// fixed-width host would measure the wrong thing.
    private func size<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
