import Foundation
import Sync

/// Reading a file's text for the compare pane: bounded, and tolerant of what real files hold.
///
/// It exists instead of `String(contentsOf:)`, which throws on invalid UTF-8, and a rotated or
/// truncated log is exactly that: the viewer would show an error with the file's readable 99% on
/// disk. Decoding the bytes leniently gives a file with a few replacement characters instead.
///
/// The dataless check comes first, before the size read and the open (the order
/// `FileContentVerifier` documents): opening a cloud-only placeholder makes the provider fetch the
/// whole file.
enum BoundedTextRead {

    /// The most a compare pane will read. Nobody reads a diff of two 40 MB logs, and the memory is
    /// two decoded strings plus the row model built from them.
    static let maxBytes = 4 * 1024 * 1024

    /// How many bytes are sniffed for a NUL before the file is called binary. A text file's first
    /// kilobyte is text; a binary one almost always has a zero byte inside it.
    static let sniffBytes = 8 * 1024

    /// The encoding the bytes were read as. Carried because the diff hides it: two files holding
    /// the same words in different encodings differ byte for byte yet diff as identical (the
    /// comparison is after decoding), so only the read can say so. Only encodings a byte-order mark
    /// names, which is what makes this decidable: a BOM is a fact about the file, not a guess.
    enum TextEncoding: String, Equatable, Sendable, CaseIterable {
        case utf8 = "UTF-8"
        case utf8WithBOM = "UTF-8 with a BOM"
        case utf16LittleEndian = "UTF-16 LE"
        case utf16BigEndian = "UTF-16 BE"
        case utf32LittleEndian = "UTF-32 LE"
        case utf32BigEndian = "UTF-32 BE"
    }

    enum Outcome: Equatable {
        /// Decoded. `lossy` is true when the bytes weren't valid in `encoding` and replacement
        /// characters were substituted; disclosed, because a diff of a lossily decoded file can show
        /// a difference that is really two different invalid sequences.
        case text(String, lossy: Bool, encoding: TextEncoding)
        case tooLarge(bytes: Int)
        case cloudOnly
        /// A NUL turned up in the sniff: this isn't lines, and rendering it as lines would show
        /// mojibake where Quick Look shows the file.
        case binary
        case unreadable

        var string: String? {
            if case .text(let value, _, _) = self { return value }
            return nil
        }

        /// How the bytes were read, or nil where nothing was read.
        var encoding: TextEncoding? {
            if case .text(_, _, let encoding) = self { return encoding }
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
            case .binary: return "Nothing readable as text here — the preview shows it properly."
            case .unreadable: return "Couldn’t be read."
            }
        }
    }

    /// Reads one side.
    ///
    /// `isCloudOnly` is injectable for the reason `FileContentVerifier.hashOutcome`'s is: a real
    /// dataless file can't be fabricated in a test, and the cloud-only branch must never open the
    /// file.
    ///
    /// No `FileManaging` seam, on purpose. The protocol has `attributesOfItem` but no
    /// `contents(atPath:)`, so a manager parameter would ask the size and the bytes of two
    /// different filesystems, the hazard `FileSyncManager+Duplicates` documents at its own
    /// `fileManager:` call sites. One filesystem, named once.
    ///
    /// A link is read as the file it points to, for all three questions. `contents(atPath:)`
    /// follows a link but `lstat` and `attributesOfItem` don't, so asking them about the link
    /// itself (always local, always tiny) would open, and so download, a link to a cloud-only file,
    /// and let a link to a 40 MB log past the cap.
    static func read(path: String,
                     isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) })
        -> Outcome {
        let path = MaterializationStatus.linkTarget(of: path)
        if isCloudOnly(path) { return .cloudOnly }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .unreadable
        }
        if (attributes[.type] as? FileAttributeType) == .typeDirectory { return .unreadable }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? (attributes[.size] as? Int) ?? 0
        if size > maxBytes { return .tooLarge(bytes: size) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        // The BOM is read before the NUL sniff: every ASCII character in a UTF-16 file is a byte
        // pair with a zero in it, so the sniff would call an ordinary text file binary, with no
        // mention of the encoding.
        if let mark = bom(of: data) {
            let body = data.dropFirst(mark.length)
            // Foundation silently drops a trailing partial code unit:
            // `String(data:encoding:.utf16LittleEndian)` over an odd number of bytes returns the
            // whole units and says nothing, so a truncated log would lose its last character
            // unannounced and one stray byte would read as the empty string. So the remainder is
            // measured here, marked as the UTF-8 path marks bad bytes, and the read reports lossy.
            let whole = body.count - (body.count % mark.unit)
            if let decoded = String(data: body.prefix(whole), encoding: mark.cocoa) {
                let truncated = whole != body.count
                return .text(decoded + (truncated ? "\u{FFFD}" : ""),
                             lossy: truncated, encoding: mark.encoding)
            }
            // A BOM that names an encoding the bytes then fail to be (an unpaired surrogate, say).
            // Not worth guessing at another: fall through to the ordinary path, which calls it
            // binary if it holds NULs and decodes it if not.
        }
        if data.prefix(sniffBytes).contains(0) { return .binary }
        // Strict first, so an ordinary file is reported as exactly itself; lossy only as the
        // fallback, and flagged.
        if let exact = String(data: data, encoding: .utf8) {
            return .text(exact, lossy: false, encoding: .utf8)
        }
        return .text(String(decoding: data, as: UTF8.self), lossy: true, encoding: .utf8)
    }

    /// The byte-order mark at the head of `data`: what it names, the `String.Encoding` to decode
    /// the rest with, how many bytes it occupies, and how wide one code unit is.
    ///
    /// The unit width is carried because Foundation silently drops a trailing partial unit, so
    /// only the caller can ask whether the body is a whole number of units.
    ///
    /// UTF-32 LE is tested before UTF-16 LE: `FF FE`, a whole UTF-16 LE BOM, is the first half of
    /// UTF-32 LE's `FF FE 00 00`, and the shorter match would read a UTF-32 file as UTF-16 with a
    /// NUL in every other character.
    ///
    /// Only BOMs, on purpose. A BOM-less UTF-16 file is detectable only by heuristic (alternating
    /// zeros), and one that misfires renders a binary file as mojibake in both panes, the harm
    /// `.binary` exists to prevent.
    static func bom(of data: Data)
        -> (encoding: TextEncoding, cocoa: String.Encoding, length: Int, unit: Int)? {
        let head = Array(data.prefix(4))
        func starts(_ bytes: [UInt8]) -> Bool {
            head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes
        }
        if starts([0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, .utf32BigEndian, 4, 4) }
        if starts([0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, .utf32LittleEndian, 4, 4) }
        if starts([0xFE, 0xFF]) { return (.utf16BigEndian, .utf16BigEndian, 2, 2) }
        if starts([0xFF, 0xFE]) { return (.utf16LittleEndian, .utf16LittleEndian, 2, 2) }
        if starts([0xEF, 0xBB, 0xBF]) { return (.utf8WithBOM, .utf8, 3, 1) }
        return nil
    }

    /// The one-line note when the two files were read as different encodings, or nil when they
    /// agree.
    ///
    /// The sibling of ``lineEndingNote(left:right:)``: the diff is over decoded text, so an
    /// encoding difference is a real byte difference that shows nowhere in the rows, and only this
    /// line says so.
    static func encodingNote(left: TextEncoding, right: TextEncoding) -> String? {
        guard left != right else { return nil }
        return "Encodings differ: \(left.rawValue) on the left, \(right.rawValue) on the right — "
            + "the lines below are compared after decoding, so the bytes differ where the text "
            + "does not."
    }

    /// Everything the notes list says about how these two files were read, in order.
    ///
    /// A function, and internal, for the reason
    /// ``DuplicateComparePrompt/trashTitle(kind:targetIsOlder:)`` is one: each rule below takes a
    /// left and a right, so a call site that swapped them would pass every rule's test and call the
    /// UTF-16 file the UTF-8 one. Inside a `Task.detached` in a view method it couldn't be
    /// asserted; here it can. Order matters: what a side is comes before how the two differ.
    static func readingNotes(left: Outcome, right: Outcome) -> [String] {
        var notes: [String] = []
        if case .text(_, lossy: true, let encoding) = left {
            notes.append("The left file is not valid \(encoding.rawValue) — unreadable bytes are shown as “\u{FFFD}”.")
        }
        if case .text(_, lossy: true, let encoding) = right {
            notes.append("The right file is not valid \(encoding.rawValue) — unreadable bytes are shown as “\u{FFFD}”.")
        }
        if let l = left.encoding, let r = right.encoding, let note = encodingNote(left: l, right: r) {
            notes.append(note)
        }
        if let leftText = left.string, let rightText = right.string,
           let note = lineEndingNote(left: leftText, right: rightText) {
            notes.append(note)
        }
        return notes
    }

    /// Splits text into lines with the line ending normalised away.
    ///
    /// CRLF against LF is a byte difference, not a content difference: a diff showing every line
    /// changed because one file came off Windows would report the line endings as the finding.
    /// The difference is reported by ``lineEndingNote(left:right:)``, not as a thousand changed
    /// lines.
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
