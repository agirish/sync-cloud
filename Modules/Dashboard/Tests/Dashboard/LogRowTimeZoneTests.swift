import AppKit
import SwiftUI
import Testing
import Events
import Design
@testable import Dashboard

/// The Activity Log's time column and the zone it reads in.
///
/// Two facts, and neither was covered. `LogEntryRow` shares one `DateFormatter` built once for the
/// process, so it kept whichever zone was current the first time a row drew — this is a window
/// people leave open, and after a flight or a Date & Time change every row would go on stamping
/// in the old zone for the rest of the session, silently. And the zone was unreachable from a
/// test, which is what let the snapshot references bake the recording machine's zone in: they
/// went red on a frozen fixture with no code change behind them when the Mac moved from Pacific
/// to `Asia/Kolkata`.
///
/// Driven through the accessor rather than by moving `NSTimeZone.default`, which is process-wide
/// and would race every other suite in the run — the same rule
/// `OrganizeRenderMemoTests.theStampFormattersFollowTheSystemZone` follows for
/// `RestructureLens.formatter(_:)`, which is the same defect one module over.
@MainActor
@Suite(.serialized) struct LogRowTimeZoneTests {

    /// 2026-06-01 12:00:00 UTC — the same frozen instant the snapshot fixtures use.
    private static let instant = Date(timeIntervalSince1970: 1_780_315_200)

    private static func row(_ zone: TimeZone) -> some View {
        LogEntryRow(
            entry: LogEntry(timestamp: instant, level: .debug, message: "Scan enumerated 1,204 items"),
            timeZone: zone)
    }

    /// **The shared formatter is put back on the requested zone before it is handed back.**
    ///
    /// Mutate it out from under the accessor and ask again: a formatter that captured its zone
    /// answers with the stale one. Both directions are driven — the app's `.current` and an
    /// injected fixed zone — because the refresh is what makes the injection reachable at all.
    @Test func theLogTimeFormatterFollowsTheZoneItIsAskedFor() throws {
        let elsewhere = try #require([TimeZone(identifier: "Asia/Kolkata"),
                                      TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })

        LogEntryRow.formatter(.current).timeZone = elsewhere
        #expect(LogEntryRow.formatter(.current).timeZone == TimeZone.current,
                "a cached formatter must be put back on the system zone before it is used")

        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(LogEntryRow.formatter(utc).timeZone == utc,
                "an injected zone must survive the accessor")
    }

    /// The reading itself, not only the property: the same instant reads differently in two
    /// zones, and reads what the zone says it should.
    @Test func theStampIsRenderedInTheZoneItIsGiven() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(LogEntryRow.formatter(utc).string(from: Self.instant) == "12:00:00.000")
        #expect(LogEntryRow.formatter(kolkata).string(from: Self.instant) == "17:30:00.000")
    }

    /// **The call-site half.** The two tests above are about a formatter; this one is about the
    /// row, and it is the one that would catch `timeZone` being accepted and then ignored — a
    /// property nothing reads is exactly the shape a rule extracted for testability decays into.
    /// Rendered, and the pixels compared: the same frozen instant in two zones five and a half
    /// hours apart must not draw the same row.
    @Test func theRowRendersTheZoneItIsGiven() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let size = CGSize(width: 400, height: 60)
        let inUTC = try #require(Self.pixels(Self.row(utc), size: size))
        let inKolkata = try #require(Self.pixels(Self.row(kolkata), size: size))
        #expect(inUTC != inKolkata,
                "the row drew the same stamp for 12:00 UTC and 17:30 IST — timeZone is not reaching the render")
    }

    /// Raw bitmap bytes for a view rendered offscreen. Deliberately not the snapshot harness:
    /// nothing here is pinned to a reference, the assertion is that two renders DIFFER.
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
