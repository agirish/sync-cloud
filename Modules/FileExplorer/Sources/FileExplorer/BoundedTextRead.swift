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

    /// The encoding the bytes were actually read as.
    ///
    /// **Carried rather than assumed, because the diff hides it.** Two files holding the same
    /// words in different encodings are byte-for-byte different and diff here as IDENTICAL — the
    /// comparison happens after decoding — so the one place that knows is the read, and it has to
    /// say so or nobody can.
    ///
    /// Only encodings a byte-order mark names, which is the whole reason this is decidable: a BOM
    /// is a fact about the file, not a guess about it.
    enum TextEncoding: String, Equatable, Sendable {
        case utf8 = "UTF-8"
        case utf8WithBOM = "UTF-8 with a BOM"
        case utf16LittleEndian = "UTF-16 LE"
        case utf16BigEndian = "UTF-16 BE"
        case utf32LittleEndian = "UTF-32 LE"
        case utf32BigEndian = "UTF-32 BE"
    }

    enum Outcome: Equatable {
        /// Decoded. `lossy` is true when the bytes were not valid in `encoding` and replacement
        /// characters were substituted — disclosed rather than hidden, because a diff of a lossily
        /// decoded file can show a difference that is really two different invalid sequences.
        case text(String, lossy: Bool, encoding: TextEncoding)
        case tooLarge(bytes: Int)
        case cloudOnly
        /// A NUL turned up in the sniff: this is not lines, and rendering it as lines would show
        /// the reader mojibake where Quick Look shows them their file.
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
        // **The BOM is read BEFORE the NUL sniff, and that order is the fix.** Every ASCII
        // character in a UTF-16 file is a byte pair with a zero in it, so the sniff called an
        // ordinary text file binary and the pane told the reader "this is not text" over a file
        // they can open in any editor — with no mention of the encoding, so there was nothing to
        // act on either.
        if let mark = bom(of: data) {
            let body = data.dropFirst(mark.length)
            // **Foundation drops a trailing partial code unit SILENTLY, and that is the whole
            // reason this is not one line.** `String(data:encoding:.utf16LittleEndian)` over an
            // odd number of bytes returns the whole units and says nothing — a truncated UTF-16
            // log came back as clean text with its last character quietly missing, and a file
            // holding one stray byte came back as the empty string. That is precisely the
            // silent-loss failure this type exists to prevent, reached through a new door. So the
            // remainder is measured here, the dropped bytes are marked the way the UTF-8 path
            // marks them, and the read reports itself lossy.
            let whole = body.count - (body.count % mark.unit)
            if let decoded = String(data: body.prefix(whole), encoding: mark.cocoa) {
                let truncated = whole != body.count
                return .text(decoded + (truncated ? "\u{FFFD}" : ""),
                             lossy: truncated, encoding: mark.encoding)
            }
            // A BOM that names an encoding the bytes then fail to be — an unpaired surrogate, say.
            // Not text in that encoding and not worth guessing at another: fall through to the
            // ordinary path below, which calls it binary if it holds NULs and decodes it if not.
        }
        if data.prefix(sniffBytes).contains(0) { return .binary }
        // Strict first, so an ordinary file is reported as exactly itself; lossy only as the
        // fallback, and flagged when it happens.
        if let exact = String(data: data, encoding: .utf8) {
            return .text(exact, lossy: false, encoding: .utf8)
        }
        return .text(String(decoding: data, as: UTF8.self), lossy: true, encoding: .utf8)
    }

    /// The byte-order mark at the head of `data`: what it names, the `String.Encoding` to decode
    /// the rest with, how many bytes it occupies, and how wide one code unit is.
    ///
    /// The unit width is carried because the caller needs it: Foundation silently drops a trailing
    /// partial unit rather than reporting one, so "is the body a whole number of units" is a
    /// question only the caller can ask, and only if it is told the width.
    ///
    /// **UTF-32 LE is tested before UTF-16 LE**, because `FF FE` — a whole UTF-16 LE BOM — is the
    /// first half of UTF-32 LE's `FF FE 00 00`, and the shorter match would read a UTF-32 file as
    /// UTF-16 whose every other character is a NUL.
    ///
    /// **Only BOMs, deliberately.** A BOM-less UTF-16 file is detectable only by heuristic — the
    /// alternating-zero pattern — and a heuristic that misfires renders a binary file as mojibake
    /// in both panes, which is the exact harm `.binary` exists to prevent. A file that says what
    /// it is gets decoded; one that does not keeps the conservative answer.
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
    /// **The sibling of ``lineEndingNote(left:right:)``, and for the same reason.** The diff is
    /// over decoded text, so an encoding difference is a real byte difference that shows up
    /// nowhere in the rows — two files the reader would call "the same" here are not the same file
    /// at all, and only this line says so.
    static func encodingNote(left: TextEncoding, right: TextEncoding) -> String? {
        guard left != right else { return nil }
        return "Encodings differ: \(left.rawValue) on the left, \(right.rawValue) on the right — "
            + "the lines below are compared after decoding, so the bytes differ where the text "
            + "does not."
    }

    /// Everything the notes list has to say about how these two files were READ, in order.
    ///
    /// **A function, and internal, for the reason ``CompareCopiesSheet/trashTitle`` is one.** The
    /// rules below are each tested where they live — and every one of them takes a left and a
    /// right, so a call site that hands them over the wrong way round satisfies all of those tests
    /// and tells the reader that the UTF-16 file is the UTF-8 one. Built inside a `Task.detached`
    /// in a private view method, that call site could not be asserted at all; here it can.
    ///
    /// Order is part of it: what a side IS comes before how the two DIFFER, so a reader meets
    /// "this one was decoded lossily" before "and they disagree about encoding".
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
