import Foundation
import PDFKit
import PDFToolkitCore
import Sync

/// **A password the PDF tools carry, which never prints.** Wrapped so that no interpolation of a
/// tool — in a log line, an assertion message, a `dump` — can spell it: its description is a
/// placeholder, its mirror has no children, and the one way to the characters is ``reveal``,
/// called at the toolkit's door.
public struct EditorPDFSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
                               CustomReflectable {
    private let value: String
    public init(_ value: String) { self.value = value }
    public var isEmpty: Bool { value.isEmpty }
    /// The characters, for `PDFToolkit` and nothing else.
    func reveal() -> String { value }
    public var description: String { "<password>" }
    public var debugDescription: String { "<password>" }
    /// No children, so `dump`, a debugger's `p` and a test's expanded failure show none either.
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// How hard Compress works — a strength, or a size to come in under.
public enum EditorPDFCompression: Equatable, Sendable {
    case quality(Double)
    case target(bytes: Int)

    /// pdf-utils' three strengths, at its quality points, so the two apps name one setting the same.
    public static let strengths: [(title: String, subtitle: String, quality: Double)] = [
        ("Best Quality", "Light savings", 0.85),
        ("Balanced", "Smaller file, still sharp", 0.6),
        ("Smallest File", "Some quality loss", 0.35),
    ]

    /// A typed megabyte figure as bytes, inside pdf-utils' bounds (0.1 MB to 500 MB) — clamped
    /// BEFORE it becomes an `Int`, which traps on a figure past `Int.max`.
    public static func bytes(megabytes: Double) -> Int {
        let clamped = megabytes.isFinite ? min(max(megabytes, 0.1), 500) : 0.1
        return Int((clamped * 1_000_000).rounded())
    }
}

/// **One of Edit's PDF tools, with what it needs.** Every one writes a NEW copy next to the
/// original and never touches the original — see ``EditorPDFCopyWriter``.
public enum EditorPDFTool: Equatable, Sendable {
    /// Zero-based pages, turned `quarterTurns` × 90° clockwise.
    case rotate(pages: [Int], quarterTurns: Int)
    case deletePages([Int])
    /// The new order: a permutation of every zero-based page.
    case reorder([Int])
    /// The pages to keep, in the order asked for — "3-5, 1" keeps 3, 4, 5, then 1.
    case extract([Int])
    case compress(EditorPDFCompression)
    case cleanMetadata(PDFMetadataFields)
    case protect(restrictEditing: Bool, password: EditorPDFSecret)
    case removePassword(EditorPDFSecret)

    public var title: String {
        switch self {
        case .rotate: return "Rotate"
        case .deletePages: return "Delete Pages"
        case .reorder: return "Reorder Pages"
        case .extract: return "Extract Pages"
        case .compress: return "Compress"
        case .cleanMetadata: return "Clean Metadata"
        case .protect: return "Protect"
        case .removePassword: return "Remove Password"
        }
    }

    /// **What the copy's name says was done** — the one table of these words. UI copy: the reader
    /// meets them in Finder, so they are plain words rather than tool ids.
    public var suffix: String {
        switch self {
        case .rotate: return "rotated"
        case .deletePages: return "pages removed"
        case .reorder: return "reordered"
        case .extract(let pages): return EditorPDFCopyName.extractSuffix(pages)
        case .compress: return "compressed"
        case .cleanMetadata: return "metadata cleaned"
        case .protect: return "protected"
        case .removePassword: return "unlocked"
        }
    }

    /// **How this tool damages a form — pdf-utils' choice per tool, copied rather than re-derived.**
    /// Its tool views pass `.formFlattened` for Compress and `.formOrphaned` for Extract, Reorder and
    /// Remove password (which rebuilds pages into a fresh document); Rotate and Delete mutate the
    /// document in place, Add password serializes it in place, and Metadata keeps a form-bearing
    /// file on its in-place path — so none of those warns. None of these tools drops bookmarks, so
    /// `checksBookmarks` is false for all of them, as it is there.
    var formLoss: OutputFidelityWarning.Loss? {
        switch self {
        case .compress: return .formFlattened
        case .extract, .reorder, .removePassword: return .formOrphaned
        case .rotate, .deletePages, .cleanMetadata, .protect: return nil
        }
    }

    /// What the log line says was done — **never a password**, which is why the two password tools
    /// name only their style.
    var logDetail: String {
        switch self {
        case .rotate(let pages, let turns):
            return "rotate \(EditorPDFCopyName.degrees(turns)) \(EditorPDFCopyName.pageList(pages))"
        case .deletePages(let pages): return "delete \(EditorPDFCopyName.pageList(pages))"
        case .reorder(let order): return "reorder to \(order.map { String($0 + 1) }.joined(separator: ", "))"
        case .extract(let pages): return "extract \(EditorPDFCopyName.pageList(pages))"
        case .compress(.quality(let quality)): return "compress \(quality)"
        case .compress(.target(let bytes)): return "compress to \(FileSyncManager.formatBytes(bytes))"
        case .cleanMetadata(let fields): return fields.isCleared ? "clean metadata (all cleared)" : "clean metadata"
        case .protect(let restrict, _): return restrict ? "protect (restrict editing)" : "protect (lock to open)"
        case .removePassword: return "remove password"
        }
    }
}

/// Names for a tool's copy, and the page lists its words use.
enum EditorPDFCopyName {
    /// Past this many characters "pages 2–4, 7, 9–12" is no longer a name anybody reads, and the
    /// copy is called "extract" instead.
    static let longestPageLabel = 28

    /// "page 3", "pages 2–4", "pages 3–5, 1" — runs collapsed, in the order asked for — or
    /// "extract" when that would not fit a file name.
    static func extractSuffix(_ pages: [Int]) -> String {
        let label = pageList(pages)
        return label.count <= longestPageLabel ? label : "extract"
    }

    /// One-based, ascending runs collapsed with an en dash, the order kept: [2,3,4,0] → "pages 3–5, 1".
    static func pageList(_ pages: [Int]) -> String {
        guard !pages.isEmpty else { return "no pages" }
        var runs: [String] = []
        var start = pages[0], end = pages[0]
        func close() { runs.append(start == end ? "\(start + 1)" : "\(start + 1)–\(end + 1)") }
        for page in pages.dropFirst() {
            if page == end + 1 { end = page } else { close(); start = page; end = page }
        }
        close()
        return (pages.count == 1 ? "page " : "pages ") + runs.joined(separator: ", ")
    }

    static func degrees(_ quarterTurns: Int) -> String {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return "90° right"
        case 2: return "180°"
        case 3: return "90° left"
        default: return "0°"
        }
    }

    /// `<base> (<suffix>).pdf` beside `original`.
    static func firstChoice(for original: String, suffix: String) -> String {
        let folder = (original as NSString).deletingLastPathComponent
        let base = ((original as NSString).lastPathComponent as NSString).deletingPathExtension
        return (folder as NSString).appendingPathComponent("\(base) (\(suffix)).pdf")
    }
}

/// **Puts a tool's bytes on disk as a NEW file, and never over anything.**
///
/// The name is `<base> (<suffix>).pdf` in the original's folder, and when that is taken, the app's
/// one keep-both rule — `FileSyncManager.generateUniqueURL`, "name 2.pdf" — rather than
/// pdf-toolkit's `uniqueURL`, so a copy made here is named the way every other copy SyncCloud makes
/// is. The write is `EditorFileStore.createNew`: staged, flushed, then moved in with `RENAME_EXCL`,
/// so a file that appears between the name being chosen and the write is refused by the kernel, not
/// replaced. That refusal takes the next name — ``EditorImageImport``'s loop, bounded the same way.
enum EditorPDFCopyWriter {
    struct EveryNameTaken: LocalizedError {
        var errorDescription: String? { "every name for the copy was taken" }
    }

    static let attempts = 64

    /// Writes `data` beside `original` and returns the path it landed at.
    ///
    /// `chooseName` is the keep-both rule; a test hands in one that answers from a stale look at the
    /// folder — the file that appears after the name was chosen, which only the write can refuse.
    nonisolated static func write(
        _ data: Data, besides original: String, suffix: String,
        chooseName: (URL, Set<String>) -> URL = { FileSyncManager.generateUniqueURL(for: $0, reserved: $1) }
    ) throws -> String {
        let wanted = URL(fileURLWithPath: EditorPDFCopyName.firstChoice(for: original, suffix: suffix))
        var refused: Set<String> = []
        for _ in 0..<attempts {
            let path = chooseName(wanted, refused).path
            do {
                try EditorFileStore.createNew(data, atPath: path)
                return path
            } catch is EditorFileStore.AlreadyExists {
                refused.insert(path)
            }
        }
        throw EveryNameTaken()
    }
}

/// **The PDF tools' half that runs in the PDFKit lane.**
///
/// pdf-toolkit's contract is that every call is synchronous, does its PDFKit work on the calling
/// thread, and owns no queue — so every call here is made inside `PDFKitSerialAccess.perform`, the
/// one lane every other parse in the process takes its turn on. Each one is handed the file's URL
/// and opens its own `PDFDocument`; the reader's document is drawn on the main thread and is never
/// passed in. Only the `…Data` functions are used: they return bytes and write nothing, and
/// ``EditorPDFCopyWriter`` decides where the bytes go.
///
/// **Compress holds the lane for its whole run**, because it is one call. Thumbnails, find and a
/// duplicate scan wait behind it — which is why it reports progress and can be cancelled between
/// pages.
enum EditorPDFToolEngine {

    /// What a run produced, crossing back from the lane.
    enum Output: Sendable, Equatable {
        /// New bytes to write.
        case bytes(Data)
        /// Compress came back with the source's own bytes: nothing was gained, so nothing is written.
        case noGain
    }

    /// Called from the lane. `progress` and `isCancelled` reach only Compress.
    nonisolated static func output(of tool: EditorPDFTool, input: URL,
                                   progress: (@Sendable (Int, Int) -> Void)?,
                                   isCancelled: (@Sendable () -> Bool)?) throws -> Output {
        switch tool {
        case .rotate(let pages, let turns):
            return .bytes(try PDFToolkit.rotateData(inputURL: input, pageIndices: pages, quarterTurns: turns))
        case .deletePages(let pages):
            return .bytes(try PDFToolkit.deletePagesData(inputURL: input, pageIndices: pages))
        case .reorder(let order):
            return .bytes(try PDFToolkit.reorderData(inputURL: input, order: order))
        case .extract(let pages):
            return .bytes(try PDFToolkit.extractData(inputURL: input, pageIndices: pages))
        case .compress(let compression):
            let data: Data
            switch compression {
            case .quality(let quality):
                data = try PDFToolkit.compressDataBounded(inputURL: input, quality: quality,
                                                          onProgress: progress, isCancelled: isCancelled)
            case .target(let bytes):
                data = try PDFToolkit.compressToTargetData(inputURL: input, targetBytes: bytes,
                                                           onProgress: progress, isCancelled: isCancelled)
            }
            // Both calls hand back the source's own bytes when the rebuild is not worth it — under
            // 5% saved, or bigger than the source. The count first: the bytes are read only when it
            // matches, which a real saving never does.
            if let size = EditorFileStore.stamp(ofPath: input.path)?.size, data.count == size,
               let original = try? Data(contentsOf: input), original == data {
                return .noGain
            }
            return .bytes(data)
        case .cleanMetadata(let fields):
            return .bytes(try PDFToolkit.writeMetadataData(inputURL: input, fields: fields))
        case .protect(let restrict, let password):
            return .bytes(try PDFToolkit.encryptData(
                inputURL: input,
                options: .addPassword(restrictEditing: restrict, password: password.reveal())))
        case .removePassword(let password):
            return .bytes(try PDFToolkit.removePasswordData(inputURL: input, password: password.reveal()))
        }
    }

    /// The run, through the lane. `perform` takes a closure that cannot throw, so the outcome
    /// crosses back as a `Result`.
    static func run(_ tool: EditorPDFTool, input: URL,
                    progress: (@Sendable (Int, Int) -> Void)? = nil,
                    isCancelled: (@Sendable () -> Bool)? = nil) async -> Result<Output, any Error> {
        await PDFKitSerialAccess.perform {
            Result { try output(of: tool, input: input, progress: progress, isCancelled: isCancelled) }
        }
    }

    /// What `tool` would lose from this file, or `nil` when the file has nothing at risk. Opens the
    /// PDF, so it runs in the lane too.
    static func fidelityWarning(for tool: EditorPDFTool, input: URL) async -> OutputFidelityWarning? {
        guard let loss = tool.formLoss else { return nil }
        return await PDFKitSerialAccess.perform {
            OutputFidelityWarning.detect(in: [input], formLoss: loss, checksBookmarks: false)
        }
    }

    // MARK: Refusals made before anything runs

    /// Why `tool` cannot run on a file of `pageCount` pages, or `nil`. Said before the lane is asked,
    /// so a selection that makes no sense never costs a turn.
    static func refusal(_ tool: EditorPDFTool, pageCount: Int) -> String? {
        switch tool {
        case .rotate(let pages, let turns):
            if pages.isEmpty { return PDFOperationError.noPagesSelected.errorDescription }
            // An empty turn hands the file back unchanged — a copy identical to its original.
            if ((turns % 4) + 4) % 4 == 0 { return "A full turn leaves every page as it is." }
            return outOfRange(pages, pageCount: pageCount)
        case .deletePages(let pages):
            if pages.isEmpty { return PDFOperationError.noPagesSelected.errorDescription }
            if let bad = outOfRange(pages, pageCount: pageCount) { return bad }
            // The toolkit throws `cannotRemoveEveryPage`; refused here first so the lane never runs.
            if Set(pages).count >= pageCount { return PDFOperationError.cannotRemoveEveryPage.errorDescription }
            return nil
        case .reorder(let order):
            // `reorderData` is `extractData` and does not check the order is a permutation: a
            // repeated page would be kept twice and a missing one dropped, under "reordered".
            guard isPermutation(order, pageCount: pageCount) else {
                return "The new order has to name every page exactly once."
            }
            if order == Array(0..<pageCount) { return "The pages are already in this order." }
            return nil
        case .extract(let pages):
            if pages.isEmpty { return PDFOperationError.noPagesSelected.errorDescription }
            return outOfRange(pages, pageCount: pageCount)
        case .compress, .cleanMetadata, .protect, .removePassword:
            return nil
        }
    }

    static func isPermutation(_ order: [Int], pageCount: Int) -> Bool {
        order.count == pageCount && Set(order) == Set(0..<pageCount)
    }

    private static func outOfRange(_ pages: [Int], pageCount: Int) -> String? {
        guard let bad = pages.first(where: { $0 < 0 || $0 >= pageCount }) else { return nil }
        return PDFOperationError.pageOutOfBounds(bad + 1).errorDescription
    }
}
