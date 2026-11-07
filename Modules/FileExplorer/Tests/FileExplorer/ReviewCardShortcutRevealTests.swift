import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The review card's keycap row under the ⌥-hold reveal: empty by default, keycaps only while ⌥ is
/// held, and the same footprint either way.
///
/// Measured on `ReviewKeyHints` directly. Hosting the whole card is vacuous: the row shares an
/// `HStack` with the taller action buttons, so deleting it changes the card's height by nothing,
/// and a pixel check there sees the `␣` badge on the Quick Look button beside the row instead.
/// Removing the gate, or branching the row out of the layout, must each fail here.
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
            // The keycaps are a dark `.quaternary` chip; without a real background they composite
            // to a zero pixel delta against the borderless window's buffer, and this would report
            // "nothing painted" whatever the code did.
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

    /// The row occupies its full footprint whether the keycaps show or not, so the card doesn't
    /// resize when ⌥ goes down and move the Copy button out from under a resting pointer.
    @Test func theHintRowKeepsItsFullFootprintInBothStates() {
        let closed = hosted(Self.hints, revealed: false).fittingSize
        let open = hosted(Self.hints, revealed: true).fittingSize
        #expect(closed == open, "the hint row resized when ⌥ went down: \(closed) → \(open)")
    }

    /// ...and that footprint is the row's real one, not zero. `closed == open` also holds for a row
    /// branched out of the layout in both states; comparing the hidden row with the row at full
    /// strength is what makes "reserved" mean something.
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
        // Four keycaps, four verbs and three separators: thousands of pixels at 2x. 500 is a floor
        // no anti-aliasing difference reaches and no real row misses.
        #expect(pixelsDiffering(atRest, revealed) > 500,
                "only \(pixelsDiffering(atRest, revealed)) pixels changed — the row did not fill in")
    }

    /// At rest the row paints nothing at all, so the card doesn't teach its shortcuts to everyone
    /// forever. Compared against a blank canvas, not the other state, so a row that merely dimmed
    /// fails.
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

    /// The whole card, as an outer net: it must not resize either. Weak on its own (see the type
    /// doc), but it catches a badge elsewhere in the card that shifts layout.
    @Test func theWholeCardIsTheSameSizeInBothStates() {
        let queue = [FileDifference(
            id: UUID(),
            relativePath: "Reports/Q3-summary.pdf",
            // Absent from disk, so the fact load resolves to its placeholders ("—", "…"), which
            // hold their own width: the layout never changes, so neither measurement can race it.
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
