import Foundation

/// **One file a run wrote, exactly as it landed** — the path the keep-both rule gave it and the
/// stamp of the file the writer created, so whoever asked can later tell that file from one that has
/// replaced or changed it (an Ask Claude card's Undo, TE294).
public struct PDFWrittenFile: Equatable, Sendable {
    /// The file it was made from — the first input, for a run over several.
    public var source: String
    public var path: String
    public var stamp: EditorFileStore.Stamp
    public var bytes: Int
    /// The copy's pages, where the run knows them.
    public var pageCount: Int?

    public init(source: String, path: String, stamp: EditorFileStore.Stamp, bytes: Int, pageCount: Int? = nil) {
        self.source = source
        self.path = path
        self.stamp = stamp
        self.bytes = bytes
        self.pageCount = pageCount
    }
}

/// **How a run asked for by a request ended** — the PDF tools', a batch's or Save as PDF's — as
/// data, for a caller with no banner to read (TE294). The banner's own words come with it, so
/// what the caller says is what the pane would have said.
public struct PDFRunResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Every file it was asked about was written.
        case wrote
        /// Some were written; ``skipped`` says why the others weren't.
        case partlyWrote
        /// Nothing was written, and nothing went wrong — already small, already under the target.
        case nothingWritten
        case cancelled
        /// The loss the run found was not the loss the asker accepted (`allow` said no).
        case declined
        case failed
        /// Another run of the same kind was going; nothing was started.
        case busy
    }

    public struct Skipped: Equatable, Sendable {
        public var path: String
        public var reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public var outcome: Outcome
    public var written: [PDFWrittenFile]
    public var skipped: [Skipped]
    /// The banner's sentence.
    public var message: String
    /// The banner's second line — a batch's reasons, a deck's pictures, a missed size target.
    public var detail: String?
    /// A file only in the cloud now, which is why it ended — the caller can offer Download.
    public var download: String?

    public init(outcome: Outcome, written: [PDFWrittenFile] = [], skipped: [Skipped] = [],
                message: String, detail: String? = nil, download: String? = nil) {
        self.outcome = outcome
        self.written = written
        self.skipped = skipped
        self.message = message
        self.detail = detail
        self.download = download
    }

    @MainActor static var busy: PDFRunResult { PDFRunResult(outcome: .busy, message: EditorPDFTools.busyMessage) }
}
