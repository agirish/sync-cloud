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
