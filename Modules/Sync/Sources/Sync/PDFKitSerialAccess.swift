import Foundation
import os

/// **One lane for every PDFKit parse in the process.**
///
/// PDFKit's text extraction is not thread-safe, and the two readers that use it — ``PDFTextExtractor``
/// for the duplicate scan's content fingerprint, and `ContentSignalExtractor` for Filing's page-1
/// tokens — each used to own a private queue. Two *serial* queues do not compose: measured over 176
/// real Chase statements, a serial pass that agreed with itself across six runs (0 documents
/// differing) started disagreeing on **4.5–6.3% of documents** as soon as a second serial queue read
/// PDFs alongside it. Nothing stops that overlapping in the app — a folder-memory survey and a
/// duplicate scan guard only their own re-entrancy, not each other.
///
/// So the lane is process-wide rather than per-reader. Everything that opens a `PDFDocument` and
/// pulls text or draws a page takes its turn here.
///
/// This covers PDFKit only. Vision recognition and plain-text reads are not PDFKit, are far slower
/// per file, and stay on their callers' concurrent queues — see `ContentSignalExtractor.workQueue`.
///
/// **One exception, and it is by construction rather than by oversight: the three mounted
/// `PDFView`s** — Compare's `PDFPairView`, the Browse/Compare column preview's `PDFPagePreview`, and
/// Edit's PDF reader, whose `EditorPDFDocument` opens (and unlocks) the document it hands the view —
/// and File ▸ Print's operation, which is the same shape. All of them open their documents through
/// this lane — each awaits ``perform`` — but a `PDFView` then LAYS OUT AND DRAWS its document on the
/// main thread, on its own schedule, and so does a print operation drawing its pages (Edit prints a
/// PDF from the reader's own document, already parsed here); there is no seam to route that
/// through. It is AppKit drawing its own view; handing it a document is the only moment the app
/// controls. So the sentence above holds for their parses, and not for the drawing they do
/// afterwards. Recorded here rather than left for the next reader to discover, because "everything
/// takes its turn here" is what keeps the 4.5–6.3% disagreement above out, and a claim that broad
/// has to name where it stops holding.
public enum PDFKitSerialAccess {

    private static let queue = DispatchQueue(label: "com.synccloud.pdfkit", qos: .utility)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var live = 0
    private nonisolated(unsafe) static var peak = 0

    /// The most parses ever running at once. Test instrumentation — serialization has no other
    /// outside signature short of the sub-2%-of-documents flake no test has a corpus to reproduce.
    /// Nothing outside tests reads it.
    ///
    /// `public` rather than internal only because the other caller, `ContentSignalExtractor`, lives
    /// in `MacApp`, which belongs to no SPM package: its tests are a separate module and cannot
    /// reach an internal symbol here. Read under the lock, and read-only: a plain
    /// `nonisolated(unsafe) var` raced the write site on every read and let any module assign to it.
    ///
    /// **There is deliberately no reset.** A reset is a second writer of a process-wide counter, and
    /// swift-testing runs a suite's tests in parallel: one test zeroing it between another's parses
    /// and that other's read makes correct serialization look like none at all. None is needed —
    /// on a serial lane this is only ever 0 or 1, so "never two at once" reads as `== 1` for the
    /// life of the process once anything has parsed, and a concurrent lane pushes it above 1 and
    /// keeps it there.
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

    /// For a caller that is **already off the cooperative pool** on its own queue: blocks there
    /// until this lane is free. Never call it from the lane itself — `DispatchQueue.sync` onto the
    /// queue you are already on deadlocks.
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync { try counted(body) }
    }

    /// For an `async` caller: hops onto the lane, which both leaves the cooperative pool and takes
    /// the turn. Preferred over `run` from async code — it parks no thread while it waits.
    public static func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: counted(body)) }
        }
    }

    /// ``perform``, for work nobody will want once its task is cancelled: `nil` without running
    /// `body` when the task is cancelled before its turn comes.
    ///
    /// **`perform` alone cannot be cancelled.** Its block is on the queue the moment the task
    /// starts, and a cancelled task's block still runs when its turn comes — Compare Copies paged
    /// past ten pages queued ten opens and draws at 1,600 px, each holding up the lane that Edit's
    /// PDFs, Print and the column preview wait on. Once `body` has started it runs to the end.
    public static func performUnlessCancelled<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T? {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
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
