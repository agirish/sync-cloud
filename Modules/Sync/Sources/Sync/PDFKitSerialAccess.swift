import Foundation
import os

/// One lane for every PDFKit parse in the process.
///
/// PDFKit's text extraction is not thread-safe, and two serial queues do not compose: with a
/// second serial queue reading PDFs alongside, a pass that agreed with itself disagreed on 4.5–6.3%
/// of documents (measured). Its readers (``PDFTextExtractor`` for the duplicate scan's fingerprint,
/// `ContentSignalExtractor` for Filing's page-1 tokens) can overlap, since a folder-memory survey
/// and a duplicate scan guard only their own re-entrancy. So the lane is process-wide: everything
/// that opens a `PDFDocument` and pulls text or draws a page takes its turn here.
///
/// PDFKit only. Vision recognition and plain-text reads are far slower per file and stay on their
/// callers' concurrent queues (`ContentSignalExtractor.workQueue`).
///
/// One exception, by construction: the mounted `PDFView`s (Compare's `PDFPairView`, the column
/// preview's `PDFPagePreview`, Edit's PDF reader via `EditorPDFDocument`) and File ▸ Print's
/// operation. Each opens its document through this lane (``perform``), but AppKit then lays out
/// and draws it on the main thread on its own schedule, with no seam to route through. Their
/// parses take a turn here; their drawing does not.
public enum PDFKitSerialAccess {

    private static let queue = DispatchQueue(label: "com.synccloud.pdfkit", qos: .utility)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var live = 0
    private nonisolated(unsafe) static var peak = 0

    /// The most parses ever running at once. Test instrumentation only: serialization has no other
    /// outside signature a test can see.
    ///
    /// `public` only because `ContentSignalExtractor` lives in `MacApp`, whose tests are a separate
    /// module. Read-only, under the lock, so no read races the write and no module can assign it.
    ///
    /// There is deliberately no reset: swift-testing runs a suite's tests in parallel, and one
    /// test zeroing it between another's parses and read would hide a concurrent lane. None is
    /// needed: on a serial lane it is only ever 0 or 1, and a concurrent one pushes it above 1 for
    /// good.
    public static var peakConcurrentParses: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    private static func counted<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        live += 1
        peak = max(peak, live)
        lock.unlock()
        defer {
            lock.lock()
            live -= 1
            lock.unlock()
        }
        return try body()
    }

    /// For a caller already off the cooperative pool on its own queue: blocks there until this
    /// lane is free. **Never** call it from the lane itself: `DispatchQueue.sync` onto the queue
    /// you are on deadlocks.
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync { try counted(body) }
    }

    /// For an `async` caller: hops onto the lane, which both leaves the cooperative pool and takes
    /// the turn. Preferred over `run` from async code, since it parks no thread while it waits.
    public static func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: counted(body)) }
        }
    }

    /// Counts the `performUnlessCancelled` blocks a task has put on the lane's queue. Test
    /// instrumentation: a test bound to one waits for its own blocks to be queued before it
    /// cancels, rather than sleeping, or reading a process-wide count other suites also bump.
    public final class QueueProbe: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        public init() {}
        public var queued: Int { count.withLock { $0 } }
        fileprivate func note() { count.withLock { $0 += 1 } }
    }

    /// The probe the calling task's `performUnlessCancelled` blocks are counted on; nil in the app.
    @TaskLocal public static var queueProbe: QueueProbe?

    /// ``perform``, for work nobody will want once its task is cancelled: `nil` without running
    /// `body` when the task is cancelled before its turn comes.
    ///
    /// `perform` alone can't be cancelled: its block is queued the moment the task starts and
    /// runs when its turn comes, so pages scrolled past would each hold up the lane Edit's PDFs,
    /// Print and the column preview wait on. Once `body` has started it runs to the end.
    public static func performUnlessCancelled<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T? {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let probe = queueProbe
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe?.note()
                queue.async {
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: counted(body))
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}
