import AppKit
import SwiftUI
import Testing
import Events
import Design
@testable import Dashboard

/// Measures a view the way AppKit will, in a real (never-ordered-in) window — the same helper
/// `PaneHeaderHeightTests` uses, for the same reason: the assertion has to be about the LAID-OUT
/// result, not about the modifiers we believe we wrote.
@MainActor
private func laidOutHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
    host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let height = host.fittingSize.height
    // Measure, then tear down: these helpers run once per width per case, and a window left
    // attached to the app for every call accumulates across the suite.
    window.contentView = nil
    window.close()
    return height
}

/// Narrowing the Activity Log window must WRAP a long message, not truncate it — in BOTH
/// densities. The message is the row: the paths and failure reasons people open this window to
/// read live in it, and compact's `lineLimit(1)` ellipsised them at the window edge with no way
/// to see the rest short of widening the window again.
@MainActor
@Suite(.serialized) struct LogRowWrapTests {

    /// A message far longer than a narrow window can hold on one line.
    private static let longMessage =
        "Loading Right Tree for path: /Users/abhishek/Library/CloudStorage/Dropbox/Documents/Immigration/Archive"

    private static func row(_ density: ListDensity) -> some View {
        LogEntryRow(
            entry: LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_315_200),
                            level: .debug,
                            message: longMessage),
            density: density)
    }

    /// The regression itself, in the density it was reported in: at the log window's 380pt floor
    /// a compact row is TALLER than at a width that fits the message on one line — i.e. it
    /// wrapped. A truncating row measures the same height at every width, which is exactly how
    /// this went unnoticed.
    @Test(arguments: [ListDensity.compact, ListDensity.comfortable])
    func longMessageWrapsWhenNarrow(density: ListDensity) {
        #expect(laidOutHeight(Self.row(density), width: 380)
                > laidOutHeight(Self.row(density), width: 900))
    }

    /// Wrapping is width-driven, not a fixed two-line allowance: narrowing further adds more
    /// lines. Pins that the text really reflows rather than being clamped to `lineLimit(2)`.
    @Test(arguments: [ListDensity.compact, ListDensity.comfortable])
    func narrowerWrapsFurther(density: ListDensity) {
        #expect(laidOutHeight(Self.row(density), width: 260)
                > laidOutHeight(Self.row(density), width: 380))
    }

    /// Wrapping must not cost the density its point: an entry that DOES fit measures the same
    /// single-line height in compact at every width, and stays shorter than the comfortable
    /// two-line block. Compact only grows for the lines that would otherwise be cut off.
    @Test func shortMessageStaysOneLineInCompact() {
        let short = LogEntryRow(
            entry: LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_315_200),
                            level: .info,
                            message: "Scan finished"),
            density: .compact)
        #expect(laidOutHeight(short, width: 380) == laidOutHeight(short, width: 900))
        #expect(laidOutHeight(short, width: 900) < laidOutHeight(Self.row(.comfortable), width: 900))
    }
}
