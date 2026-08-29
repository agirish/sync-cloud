import AppKit
import SwiftUI
import Testing
import FileExplorer
@testable import SyncCloud

/// The lens names a Help topic; this is the half that checks the book actually has it
/// (proposal O14). The two live in different modules, so nothing but a test joins them.
@MainActor
@Suite struct RestructureHelpTopicTests {

    /// **The pointer must resolve.** An id that does not exist opens the book at its front,
    /// which is a silent failure — the reader asked for a page and got the cover.
    @Test func theLensPointsAtATopicTheBookHas() {
        let ids = HelpBook.sections.flatMap { $0.topics.map(\.id) }
        #expect(ids.contains(OrganizeHelpTopics.restructure),
                "the lens points at \(OrganizeHelpTopics.restructure), which the book does not have")
    }

    /// And it points at the RIGHT one: the page about what Restructure finds, not a neighbour.
    @Test func theTopicIsTheOneAboutRestructure() throws {
        let topic = try #require(HelpBook.sections.flatMap(\.topics)
            .first { $0.id == OrganizeHelpTopics.restructure })
        #expect(topic.title.contains("Restructure"))
    }

    /// An unresolvable id opens the front of the book rather than a blank card — a broken
    /// pointer is a disappointment, not a crash.
    @Test func anUnknownTopicFallsBackToTheFront() {
        let ids = HelpBook.sections.flatMap { $0.topics.map(\.id) }
        #expect(!ids.contains("no-such-topic"))
        #expect(HelpBook.sections.first?.topics.first?.id != nil,
                "there has to be a front page to fall back to")
    }

    // MARK: The book actually opens there

    /// Magenta, because an offscreen `NSHostingView` rasterizes transparent and a blank render
    /// then reads identical to a drawn one.
    @MainActor
    private static func raster(openAt topic: String?) -> NSBitmapImageRep? {
        let view = ZStack {
            Color(red: 1, green: 0, blue: 1)
            HelpView(available: CGSize(width: 900, height: 640), openAt: topic, onClose: {})
        }
        .frame(width: 900, height: 640)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard let da = a.bitmapData, let db = b.bitmapData,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 0 }
        let bpr = min(a.bytesPerRow, b.bytesPerRow), spp = a.samplesPerPixel
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let p = y * bpr + x * spp
                if abs(Int(da[p]) - Int(db[p])) > 8 || abs(Int(da[p + 1]) - Int(db[p + 1])) > 8
                    || abs(Int(da[p + 2]) - Int(db[p + 2])) > 8 {
                    count += 1
                }
            }
        }
        return count
    }

    /// **The pointer opens the book somewhere else.** Everything above this checks the id exists;
    /// none of it checked that passing it changes what the reader sees — deleting the `openAt`
    /// resolution from `HelpView.init` left the whole suite green, with every reader landing on
    /// the front page exactly as before the feature.
    @Test func openingAtTheTopicShowsADifferentPageFromTheFront() throws {
        let front = try #require(Self.raster(openAt: nil))
        let restructure = try #require(Self.raster(openAt: OrganizeHelpTopics.restructure))
        #expect(Self.differingPixels(front, restructure) > 500,
                "the book opened at Restructure's page, not its cover")
    }

    /// And the fallback is the *rendered* front page, not merely a resolved-to-nil id: a broken
    /// pointer must be a disappointment, never a blank card.
    @Test func anUnknownTopicRendersTheFrontPage() throws {
        let front = try #require(Self.raster(openAt: nil))
        let broken = try #require(Self.raster(openAt: "no-such-topic"))
        #expect(Self.differingPixels(front, broken) == 0,
                "an id the book does not have opens the front, drawn the same way")
    }
}
