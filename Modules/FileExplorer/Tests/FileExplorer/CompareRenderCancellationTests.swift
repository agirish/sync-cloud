import Testing
import Foundation
import CoreGraphics
import os
@testable import FileExplorer
import Sync

/// **A cancelled page render never opens or draws its page** (speed audit item 10).
///
/// Compare Copies renders the page on screen through `.task(id:)`, which cancels the render when
/// the page moves. Before `performUnlessCancelled`, a render's block was on the PDF lane from the
/// moment its task started and ran whatever happened to the task, so paging past ten pages drew
/// ten pages at 1,600 px — ahead of Edit's PDFs, Print and the column preview, which share the
/// lane. The lane is held for each test so the renders are queued behind it, which is the case
/// that matters: a lane that is free runs a render before anyone can cancel it.
@MainActor
@Suite(.serialized) struct CompareRenderCancellationTests {

    /// Block the lane, queue three, cancel two: one runs.
    @Test func ofThreeQueuedCancellingTwoRunsOne() async throws {
        let hold = LaneHold()
        defer { hold.release() }
        #expect(await hold.waitUntilHeld(), "the lane was never held — the renders below could run before the cancel")
        let ran = OSAllocatedUnfairLock(initialState: [Int]())
        let tasks = (0..<3).map { n in
            Task.detached { () -> Int? in
                await PDFKitSerialAccess.performUnlessCancelled { ran.withLock { $0.append(n) }; return n }
            }
        }
        // Long enough for all three to reach the lane's queue: the case being proved is a block
        // already queued when its task is cancelled, not one refused before it was queued.
        try await Task.sleep(nanoseconds: 200_000_000)
        tasks[0].cancel()
        tasks[1].cancel()
        hold.release()
        let results = [await tasks[0].value, await tasks[1].value, await tasks[2].value]
        #expect(results == [nil, nil, 2])
        #expect(ran.withLock { $0 } == [2], "cancelled renders still ran: \(ran.withLock { $0 })")
    }

    /// `PagePairRaster.render` is the caller that takes it: a cancelled render answers nil, and the
    /// one still wanted draws its page.
    @Test func aCancelledPageRenderDrawsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompareRenderCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("one.pdf").path
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        context.endPDFPage()
        context.closePDF()

        let hold = LaneHold()
        defer { hold.release() }
        #expect(await hold.waitUntilHeld())
        let passed = Task.detached { await PagePairRaster.render(path: path, page: 0, longEdge: 160) }
        let stoppedOn = Task.detached { await PagePairRaster.render(path: path, page: 0, longEdge: 160) }
        try await Task.sleep(nanoseconds: 200_000_000)
        passed.cancel()
        hold.release()
        #expect(await passed.value == nil, "a page the reader paged past was still rendered")
        let image = await stoppedOn.value
        #expect(image?.cgImage.width == 107 && image?.cgImage.height == 160,
                "the page the reader stopped on did not render: \(String(describing: image?.cgImage.width))")
    }
}
