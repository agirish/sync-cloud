import Foundation

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
public enum PDFKitSerialAccess {

    private static let queue = DispatchQueue(label: "com.synccloud.pdfkit", qos: .utility)

    /// The most parses ever running at once. Test instrumentation — serialization has no other
    /// outside signature short of the sub-2%-of-documents flake no test has a corpus to reproduce.
    /// Nothing outside tests reads it.
    ///
    /// `public` rather than internal only because the other caller, `ContentSignalExtractor`, lives
    /// in `MacApp`, which belongs to no SPM package: its tests are a separate module and cannot
    /// reach an internal symbol here.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var live = 0
    public nonisolated(unsafe) static var peakConcurrentParses = 0

    /// Deliberately leaves the live count alone: zeroing it under an in-flight parse drives it
    /// negative on the next decrement, and the peak then never rises above zero again.
    public static func resetPeakConcurrentParses() {
        lock.lock()
        peakConcurrentParses = 0
        lock.unlock()
    }

    private static func counted<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        live += 1
        peakConcurrentParses = max(peakConcurrentParses, live)
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
}
