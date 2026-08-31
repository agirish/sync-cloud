import Foundation
import Sync

/// Reading a file's text for the compare pane — bounded, and tolerant of what real files hold.
///
/// **`String(contentsOf:)` is the thing this exists instead of.** It throws on invalid UTF-8, and
/// a rotated or truncated log is exactly that: this app has already shipped a viewer that showed
/// an error where a file's readable 99% was sitting on disk. Reading the bytes and decoding them
/// leniently turns an unreadable file into a file with a few replacement characters in it, which
/// is what the reader actually wants.
///
/// **The dataless check comes first**, before the size read, before the open — the order
/// `FileContentVerifier` documents. A cloud-only placeholder is a placeholder whatever else is
/// true of it, and opening one is what makes the provider fetch the whole file.
enum BoundedTextRead {

    /// The most a compare pane will read. A diff of two 40 MB logs is not a thing anyone looks at,
    /// and the memory is two decoded strings plus the row model built from them.
    static let maxBytes = 4 * 1024 * 1024

    /// How many bytes are sniffed for a NUL before the file is called binary. A text file's first
    /// kilobyte is text; a binary one almost always has a zero byte inside it.
    static let sniffBytes = 8 * 1024

    enum Outcome: Equatable {
        /// Decoded. `lossy` is true when the bytes were not valid UTF-8 and replacement characters
        /// were substituted — disclosed rather than hidden, because a diff of a lossily decoded
        /// file can show a difference that is really two different invalid sequences.
        case text(String, lossy: Bool)
        case tooLarge(bytes: Int)
        case cloudOnly
        /// A NUL turned up in the sniff: this is not lines, and rendering it as lines would show
        /// the reader mojibake where Quick Look shows them their file.
        case binary
        case unreadable

        var string: String? {
            if case .text(let value, _) = self { return value }
            return nil
        }

        /// Why there is no text, in the reader's words. nil when there is text.
        var caption: String? {
            switch self {
            case .text: return nil
            case .tooLarge(let bytes):
                return "Too large to diff (\(FileSyncManager.formatBytes(bytes)); the limit is "
                    + "\(FileSyncManager.formatBytes(maxBytes)))."
            case .cloudOnly: return "Not downloaded — there is nothing here to read yet."
            case .binary: return "This is not text — the preview shows it properly."
            case .unreadable: return "Couldn't be read."
            }
        }
    }

    /// Reads one side.
    ///
    /// `isCloudOnly` is injectable for the reason `FileContentVerifier.hashOutcome`'s is: a real
    /// dataless file cannot be fabricated in a test, the flag is provider-set, and the cloud-only
    /// branch is the one that must never open the file.
    ///
    /// **There is deliberately no `FileManaging` seam here, and that is a decision rather than an
    /// omission.** The protocol carries `attributesOfItem` but no `contents(atPath:)`, so a
    /// manager parameter would route the stat through the seam and the BYTES through
    /// `FileManager.default` — the size verdict and the read asked of two different filesystems,
    /// which is the exact hazard `FileSyncManager+Duplicates` documents at its own `fileManager:`
    /// call sites. One filesystem, named once.
    static func read(path: String,
                     isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) })
        -> Outcome {
        if isCloudOnly(path) { return .cloudOnly }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .unreadable
        }
        if (attributes[.type] as? FileAttributeType) == .typeDirectory { return .unreadable }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? (attributes[.size] as? Int) ?? 0
        if size > maxBytes { return .tooLarge(bytes: size) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        if data.prefix(sniffBytes).contains(0) { return .binary }
        // Strict first, so an ordinary file is reported as exactly itself; lossy only as the
        // fallback, and flagged when it happens.
        if let exact = String(data: data, encoding: .utf8) { return .text(exact, lossy: false) }
        return .text(String(decoding: data, as: UTF8.self), lossy: true)
    }

    /// Splits text into lines with the line ending normalised away.
    ///
    /// **CRLF against LF is a byte difference, not a content difference**, and a diff that showed
    /// every line as changed because one file came off Windows would be reporting the encoding as
    /// the finding. The difference is real and is reported — see ``lineEndingNote(left:right:)`` —
    /// just not as a thousand changed lines.
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// The one-line note when the two files use different line endings, or nil when they agree.
    static func lineEndingNote(left: String, right: String) -> String? {
        func ending(_ text: String) -> String {
            if text.contains("\r\n") { return "CRLF" }
            if text.contains("\r") { return "CR" }
            return "LF"
        }
        let l = ending(left), r = ending(right)
        guard l != r else { return nil }
        return "Line endings differ: \(l) on the left, \(r) on the right — the lines below are "
            + "compared without them."
    }
}
