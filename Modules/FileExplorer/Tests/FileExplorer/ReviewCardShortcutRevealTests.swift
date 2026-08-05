import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The review card's key-cap row after it joined the ⌥-hold reveal: empty by default, keycaps only
/// while ⌥ is held, and the same footprint either way.
///
/// **Measured on `ReviewKeyHints` directly, and that is the point of this file.** The obvious test
/// — host the whole card, assert its size doesn't change — is vacuous: the row sits in an `HStack`
/// with the action buttons, which are taller than it is, so deleting the row outright changes the
/// card's height by nothing. The first version of this file did exactly that and passed against
/// *both* mutations it was written to catch: gate-removed and row-branched-out-of-the-layout. Its
/// pixel half was worse than useless, because it was detecting the `␣` badge on the Quick Look
/// button beside the row rather than the row.
@MainActor
@Suite(.serialized) struct ReviewCardShortcutRevealTests {

    private static let canvas = CGSize(width: 420, height: 40)

    private static let hints = ReviewKeyHints(primaryVerb: "Copy")

    private func hosted(_ view: some View, revealed: Bool) -> NSHostingView<AnyView> {
        NSHostingView(rootView: AnyView(view.environment(\.shortcutRevealActive, revealed)))
    }

    private func render(_ view: some View, revealed: Bool) -> NSBitmapImageRep? {
        let subject = view
            .environment(\.shortcutRevealActive, revealed)
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .leading)
            // The keycaps are a dark `.quaternary` chip; without a real background behind them they
            // composite to a zero pixel delta against the borderless window's own buffer, and this
            // test would report "nothing painted" whatever the code did.
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var differing = 0
        for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    // MARK: The reservation

    /// The row occupies its full footprint whether the keycaps are showing or not — which is what
    /// keeps the card from resizing when ⌥ goes down and moving the Copy button out from under a
    /// pointer that is already resting on it, mid-review.
    @Test func theHintRowKeepsItsFullFootprintInBothStates() {
        let closed = hosted(Self.hints, revealed: false).fittingSize
        let open = hosted(Self.hints, revealed: true).fittingSize
        #expect(closed == open, "the hint row resized when ⌥ went down: \(closed) → \(open)")
    }

    /// ...and that footprint is the row's real one, not zero.
    ///
    /// This is the assertion the vacuous version was missing. `closed == open` is satisfied just as
    /// well by a row that has been branched out of the layout in *both* states — comparing the
    /// hidden row against the row at full strength is what makes "reserved" mean something.
    @Test func theReservedFootprintIsTheRowAtFullStrength() {
        let reserved = hosted(Self.hints, revealed: false).fittingSize
        let full = hosted(Self.hints.row, revealed: false).fittingSize
        #expect(reserved == full,
                "the hidden row reserves \(reserved) but the visible row needs \(full)")
        #expect(full.height > 0 && full.width > 0, "the fixture row measured nothing: \(full)")
    }

    // MARK: The gating

    /// Empty at rest, full during the reveal. Pixels rather than the accessibility tree: under
    /// `swift test` there is no assistive client, so a caption assertion passes vacuously whether
    /// or not anything was drawn.
    @Test(.machinePinned(.pixelSampling))
    func theKeycapsArePaintedOnlyDuringTheReveal() {
        guard let atRest = render(Self.hints, revealed: false),
              let revealed = render(Self.hints, revealed: true) else {
            Issue.record("no bitmap rep")
            return
        }
        // Four keycaps, four verbs and three separators — thousands of pixels at 2x. 500 is a floor
        // no anti-aliasing difference reaches and no real row misses.
        #expect(pixelsDiffering(atRest, revealed) > 500,
                "only \(pixelsDiffering(atRest, revealed)) pixels changed — the row did not fill in")
    }

    /// At rest the row paints *nothing at all*, which is the actual product change: the card no
    /// longer teaches its shortcuts at everyone forever. Compared against a blank canvas rather
    /// than against the other state, so a row that merely dimmed would fail this.
    @Test(.machinePinned(.pixelSampling))
    func theRowPaintsNothingAtRest() {
        guard let atRest = render(Self.hints, revealed: false),
              let blank = render(Color.clear, revealed: false) else {
            Issue.record("no bitmap rep")
            return
        }
        #expect(pixelsDiffering(atRest, blank) == 0,
                "\(pixelsDiffering(atRest, blank)) pixels of the hint row are still painted at rest")
    }

    // MARK: End-to-end

    /// The whole card, as an outer net: it must not resize either. Weak on its own — see the type
    /// doc — but it is the assertion that would catch someone reserving the row correctly and then
    /// putting a *badge* somewhere in the card that does shift layout.
    @Test func theWholeCardIsTheSameSizeInBothStates() {
        let queue = [FileDifference(
            id: UUID(),
            relativePath: "Reports/Q3-summary.pdf",
            // Deliberately absent from disk, so the card's fact load resolves to its placeholders
            // ("—", "…") — which hold their own width, so the layout it settles at is the one it
            // starts at and neither measurement can race it.
            leftItemPath: "/nonexistent-left/Reports/Q3-summary.pdf",
            rightItemPath: "/nonexistent-right/Reports/Q3-summary.pdf",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )]
        guard let session = ReviewSession(queue: queue, isMove: false, pathRootName: nil) else {
            Issue.record("fixture queue produced no session")
            return
        }
        let card = ReviewCardView(
            session: session,
            paneNames: PaneProviderNames(leftName: "iCloud", rightName: "Dropbox"),
            accent: Color(red: 0, green: 0.44, blue: 0.91),
            fileManager: FileManager.default,
            onQuickLook: { _ in },
            isActing: false,
            focusNudge: 0,
            onPrimary: { _ in },
            onSkip: { _ in },
            onVerdict: { _, _, _ in },
            onExit: {}
        ).frame(width: 720)

        let closed = hosted(card, revealed: false).fittingSize
        let open = hosted(card, revealed: true).fittingSize
        #expect(closed == open, "the review card resized when ⌥ went down: \(closed) → \(open)")
    }
}
