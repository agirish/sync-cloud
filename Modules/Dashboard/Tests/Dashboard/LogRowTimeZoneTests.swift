import AppKit
import SwiftUI
import Testing
import Events
import Design
@testable import Dashboard

/// The Activity Log's time column and the zone it reads in. `LogEntryRow` shares one process-wide
/// `DateFormatter`, so one that kept its first zone would stamp every row of a window left open in
/// the old zone after a flight or a Date & Time change. Driven through the accessor, never by moving
/// `NSTimeZone.default`, which is process-wide and would race every other suite (as in
/// `OrganizeRenderMemoTests.theStampFormattersFollowTheSystemZone`). The rule is tested on
/// `Design.ZoneRefreshedFormatter`; these assert the row routes through it.
@MainActor
@Suite(.serialized) struct LogRowTimeZoneTests {

    /// 2026-06-01 12:00:00 UTC, the same frozen instant the snapshot fixtures use.
    private static let instant = Date(timeIntervalSince1970: 1_780_315_200)

    private static func row(_ zone: TimeZone) -> some View {
        LogEntryRow(
            entry: LogEntry(timestamp: instant, level: .debug, message: "Scan enumerated 1,204 items"),
            timeZone: zone)
    }

    /// The reading itself, not only the property: the same instant reads differently in two
    /// zones, and reads what the zone says it should.
    @Test func theStampIsRenderedInTheZoneItIsGiven() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(LogEntryRow.timeFormatter.string(from: Self.instant, in: utc) == "12:00:00.000")
        #expect(LogEntryRow.timeFormatter.string(from: Self.instant, in: kolkata) == "17:30:00.000")
    }

    /// The call-site half: the row must use its `timeZone`, not accept and ignore it. Rendered and
    /// compared: the same instant in two zones five and a half hours apart must not draw the same
    /// row.
    @Test func theRowRendersTheZoneItIsGiven() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let size = CGSize(width: 400, height: 60)
        let inUTC = try #require(Self.pixels(Self.row(utc), size: size))
        let inKolkata = try #require(Self.pixels(Self.row(kolkata), size: size))
        #expect(inUTC != inKolkata,
                "the row drew the same stamp for 12:00 UTC and 17:30 IST — timeZone is not reaching the render")
    }

    /// Raw bitmap bytes for a view rendered offscreen. Not the snapshot harness: nothing is pinned
    /// to a reference; the assertion is that two renders differ.
    private static func pixels<V: View>(_ view: V, size: CGSize) -> Data? {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
