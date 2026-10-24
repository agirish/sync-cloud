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

    /// A typed megabyte figure as bytes, floored at pdf-utils' 0.1 MB and clamped BEFORE it becomes
    /// an `Int`, which traps on a figure past `Int.max`.
    ///
    /// **The ceiling is a terabyte, not pdf-utils' 500 MB**: the target is also what "already under
    /// it" is measured against, and a 600 MB scan with "1000" typed was clamped to 500 MB and
    /// rasterized at every rung instead of being told it already fits.
    public static func bytes(megabytes: Double) -> Int {
        let clamped = megabytes.isFinite ? min(max(megabytes, 0.1), 1_000_000) : 0.1
        return Int((clamped * 1_000_000).rounded())
    }

    /// The most a size target starts at, in megabytes — pdf-utils' default.
    public static let startingCeiling = 2.0

    /// **Compress's "Under [ ] MB", as the sheet opens** — about half the file, to one decimal
    /// place, and never above 2 MB: always "2" left a file already under 2 MB with nothing to do
    /// but "already under the 2 MB target — nothing was written". Not below the 0.1 MB floor
    /// ``bytes(megabytes:)`` holds every target to. "2" when the size is not known.
    public static func startingTarget(forSize bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return figure(startingCeiling) }
        let half = (Double(bytes) / 2 / 1_000_000 * 10).rounded() / 10
        return figure(min(max(half, 0.1), startingCeiling))
    }

    /// "0.7", "1.5", "2" — the field's figure, with no trailing ".0".
    private static func figure(_ megabytes: Double) -> String {
        megabytes == megabytes.rounded() ? String(Int(megabytes)) : String(format: "%.1f", megabytes)
    }

    /// **The line under the size field: what the size does, or why Save is greyed** (PD9) — read
    /// from ``megabytes(_:)``, the rule the button greys by, so the two cannot disagree. Typing 0 or
    /// clearing the field greyed Save with nothing said; the page-range sheet says why in red.
    static func targetCaption(_ typed: String) -> (text: String, isError: Bool) {
        if megabytes(typed) != nil { return ("Tries lower quality until the file fits.", false) }
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ("Type a size in MB to come in under, like 2.", true) }
        return ("“\(trimmed)” isn’t a size — type a number of MB above 0, like 2.", true)
    }

    /// A typed figure — "1.5", "2,5", "1,000", " 2 " — or `nil` for one that is not a positive
    /// number. A comma is a decimal point only where it can be one: alone, with at most two digits
    /// after it. "1,000" is a thousand, not one.
    public static func megabytes(_ typed: String) -> Double? {
        var text = typed.trimmingCharacters(in: .whitespaces)
        if text.contains(".") {
            text = text.replacingOccurrences(of: ",", with: "")
        } else if let comma = text.firstIndex(of: ","), text.filter({ $0 == "," }).count == 1,
                  text.distance(from: comma, to: text.endIndex) <= 3 {
            text.replaceSubrange(comma...comma, with: ".")
        } else {
            text = text.replacingOccurrences(of: ",", with: "")
        }
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
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
    /// What Fill & Sign placed, as the toolkit draws it — ``EditorPDFFillSign/save()`` — and the
    /// zero-based pages then made pictures, so the words corrections cover there go (TE85).
    case fillAndSign([FillSignItem], pictures: [Int] = [])
    /// **Fill & Sign on a file with its own form** (Phase 5c): the values typed into its fields, by
    /// fully qualified name, and what was placed — filled in place by `fillFormData`, so the copy's
    /// form stays fillable and the placed items become annotations rather than page content.
    case fillForm(values: [String: FormFieldValue], items: [FillSignItem])
    /// **Rotate or Delete Pages with a dragged order pending** — `then` on the original, its pages
    /// then put in `order` (the Pages tab's arrangement, in the file's own page numbers): one copy
    /// that does both. Made only by ``composing(_:arrangement:)``.
    indirect case arranged(order: [Int], then: EditorPDFTool)

    /// **The tool a run performs while the reader has a page order pending** (decided 2026-10-18:
    /// "use the new order"). Rotate and Delete Pages take the order along — the copy comes out in
    /// the dragged order with the change applied.
    ///
    /// **Extract does not**: the pages typed ARE its order, page by page, so a pending one has
    /// nothing left to say — and the Pages tab's prefill already lists a selection as it is shown.
    /// Nothing else takes it either: the order stays pending for Save Reordered Copy.
    static func composing(_ tool: EditorPDFTool, arrangement: [Int]?) -> EditorPDFTool {
        guard let arrangement else { return tool }
        switch tool {
        case .rotate, .deletePages:
            // A delete that took every moved page leaves the rest in the file's order — a plain
            // delete, named as one, with no reorder to orphan a form.
            let order = EditorPDFToolEngine.order(arrangement, after: tool)
            return order == Array(order.indices) ? tool : .arranged(order: arrangement, then: tool)
        default:
            return tool
        }
    }

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
        case .fillAndSign, .fillForm: return "Fill & Sign"
        case .arranged(_, let then): return then.title
        }
    }

    /// **The run in words, for a sentence that names it** — "Stop rotating the pages?", "Compressing
    /// was cancelled". Lower case: a sentence that starts with it capitalises it
    /// (``EditorPDFTools/Running``). A bare title read "Stop Rotate?" and "Protect cancelled".
    public var doing: String {
        switch self {
        case .rotate: return "rotating the pages"
        case .deletePages: return "deleting the pages"
        case .reorder: return "saving the new page order"
        case .extract: return "extracting the pages"
        case .compress: return "compressing"
        case .cleanMetadata: return "cleaning the metadata"
        case .protect: return "protecting with a password"
        case .removePassword: return "removing the password"
        case .fillAndSign, .fillForm: return "saving the filled copy"
        case .arranged(_, let then): return then.doing
        }
    }

    /// The leave question's sentence for a run still in flight — "The pages are still being rotated."
    public var stillRunning: String {
        switch self {
        case .rotate: return "The pages are still being rotated."
        case .deletePages: return "The pages are still being deleted."
        case .reorder: return "The new page order is still being saved."
        case .extract: return "The pages are still being extracted."
        case .compress: return "This PDF is still being compressed."
        case .cleanMetadata: return "The metadata is still being cleaned."
        case .protect: return "The password is still being added."
        case .removePassword: return "The password is still being removed."
        case .fillAndSign, .fillForm: return "The filled copy is still being saved."
        case .arranged(_, let then): return then.stillRunning
        }
    }

    /// **What the copy's name says was done** — the one table of these words. UI copy: the reader
    /// meets them in Finder, so they are plain words rather than tool ids.
    public var suffix: String {
        switch self {
        case .rotate: return "rotated"
        // "page removed" for one page, as Extract says "page 3" for one.
        case .deletePages(let pages): return pages.count == 1 ? Self.pageRemoved : Self.pagesRemoved
        case .reorder: return "reordered"
        case .extract(let pages): return EditorPDFCopyName.extractSuffix(pages)
        case .compress: return "compressed"
        case .cleanMetadata: return "metadata cleaned"
        case .protect: return "protected"
        case .removePassword: return "unlocked"
        // "(signed)" when it carries a signature or initials, drawn or typed; "(corrected)" when it
        // carries corrections and nothing else (TE84) — each is a patch and its words; "(filled)"
        // otherwise (decided with the 5b mockups). The name follows the save button, which says
        // Save Corrected Copy for corrections alone and Save Filled Copy for a mix (decided
        // 2026-10-21: a mix was "(corrected)" under a Save Filled Copy button).
        case .fillAndSign(let items, _):
            if items.contains(where: Self.isSigned) { return "signed" }
            let patches = items.filter(\.isPatch).count
            return patches > 0 && items.count == 2 * patches ? "corrected" : "filled"
        case .fillForm(_, let items):
            return items.contains(where: Self.isSigned) ? "signed" : "filled"
        // "Invoice (reordered, rotated).pdf" — the reorder's word, then the tool's.
        case .arranged(_, let then): return "\(Self.reorder([]).suffix), \(then.suffix)"
        }
    }

    /// Delete's word, by count — one word to a copy of a copy (``EditorPDFCopyName/withoutSuffix(_:_:)``).
    static let pageRemoved = "page removed"
    static let pagesRemoved = "pages removed"

    /// **How this tool damages a form — pdf-utils' choice per tool, copied rather than re-derived.**
    /// Its tool views pass `.formFlattened` for Compress and Fill & Sign (`FillSignToolView`, which
    /// redraws every page into a fresh context), and `.formOrphaned` for Extract, Reorder and
    /// Remove password (which rebuilds pages into a fresh document); Rotate and Delete mutate the
    /// document in place, Add password serializes it in place, and Metadata keeps a form-bearing
    /// file on its in-place path — so none of those warns. None of these tools drops bookmarks, so
    /// `checksBookmarks` is false for all of them, as it is there.
    var formLoss: OutputFidelityWarning.Loss? {
        switch self {
        case .compress, .fillAndSign: return .formFlattened
        case .extract, .reorder, .removePassword: return .formOrphaned
        // Filled in place: the form, its widgets and everything else the file carries survive.
        case .rotate, .deletePages, .cleanMetadata, .protect, .fillForm: return nil
        // The reorder step rebuilds the pages into a fresh document, as Reorder alone does — so a
        // combined Rotate or Delete warns where either alone would not.
        case .arranged: return .formOrphaned
        }
    }

    /// **Whether the copy loses the file's tags, layers and colour output intent** (decision BW) —
    /// every tool whose copy is rebuilt or whose page tree changes. Rotate, Protect and filling a
    /// form write the document in place and keep them, and so does Clean Metadata on a file with a
    /// form, which it cleans in place (the toolkit's `writeMetadataData`).
    ///
    /// **Not on macOS 26** (FR53). There PDFKit drops the catalog on every write, in place or not.
    /// The toolkit carries four parts back onto an unencrypted copy — page labels, viewer settings,
    /// language, attachments — but never tags, layers or colour output intent, and nothing at all
    /// onto an encrypted one. So below 27 Rotate, Protect, filling a form and cleaning a form's
    /// metadata lose the three parts this note names, and the sheet has to say so.
    func dropsCatalogParts(fileHasForm: Bool,
                           osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool {
        switch self {
        case .deletePages, .reorder, .extract, .compress, .removePassword, .fillAndSign, .arranged: return true
        case .cleanMetadata: return !fileHasForm || osMajor < 27
        case .rotate, .protect, .fillForm: return osMajor < 27
        }
    }

    /// What Protect's copy loses on macOS 26 beyond the three parts every note names: the toolkit
    /// skips its carry for encrypted output, so the four parts it carries elsewhere go too. Nil
    /// from 27. Said whatever the file holds rather than naming only what it has — a deliberate
    /// simplification: the sentence is true of every file, and reading the catalog for it would
    /// be one more pass over a file the sheet has not opened.
    static func protectedCopyNote(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String? {
        osMajor < 27 ? "On macOS 26 the protected copy won’t keep attached files, page labels, viewer settings or language." : nil
    }

    /// **Whether the copy's bytes are serialized from a FRESH document rather than the loaded one**
    /// — the question being whether a restricted original's encryption dictionary survives. It is
    /// not "copies pages", which is the form question ``formLoss`` answers; the two differ.
    ///
    /// - Extract and Reorder copy pages into a new `PDFDocument`; Compress draws them into a new
    ///   `CGPDFContext`, and so does Fill & Sign; Remove Password rebuilds on purpose. None carries
    ///   the original's encryption.
    /// - Rotate and Delete mutate the LOADED document and serialize it, and PDFKit carries its
    ///   encryption across (the toolkit's `removePasswordData` notes the same of an unlocked file).
    ///   Both are refused on a restricted file in any case (`permissionsForbidEditing`).
    /// - Protect writes encryption of its own.
    /// - Clean Metadata copies into a fresh document only for a file with no form — and it is never
    ///   offered on an encrypted file (`metadataEncrypted`), so its answer here is never read.
    var rebuildsDocument: Bool {
        switch self {
        case .extract, .reorder, .compress, .cleanMetadata, .removePassword, .fillAndSign: return true
        // `fillFormData` mutates the document opened from the file and serializes it, so a
        // restricted original's encryption — and its restrictions — carry into the copy.
        case .rotate, .deletePages, .protect, .fillForm: return false
        // The reorder step comes last. (Its first step is refused on a restricted file anyway.)
        case .arranged: return true
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
        case .fillAndSign(let items, let pictures):
            // Counts only — the words and the strokes are the reader's, and never logged. A
            // correction is two of the toolkit's items, its patch and its words: counted once.
            let signatures = items.filter(Self.isSigned).count
            let corrections = items.filter(\.isPatch).count
            let others = items.count - 2 * corrections
            var parts = others > 0 || corrections == 0 ? [EditorPDFFillSign.count(others)] : []
            if corrections > 0 { parts.append(EditorPDFFillSign.corrections(corrections)) }
            if signatures > 0 { parts.append(signatures == 1 ? "1 signature" : "\(signatures) signatures") }
            if !pictures.isEmpty { parts.append("\(EditorPDFCopyName.pageList(pictures)) made a picture") }
            return "fill and sign (\(parts.joined(separator: ", ")))"
        case .fillForm(let values, let items):
            // Counts only, as above: never a field's name, which can say what the form is about.
            let signatures = items.filter(Self.isSigned).count
            var parts = [EditorPDFFillSign.fields(values.count)]
            if !items.isEmpty { parts.append(EditorPDFFillSign.count(items.count)) }
            if signatures > 0 { parts.append(signatures == 1 ? "1 signature" : "\(signatures) signatures") }
            return "fill form (\(parts.joined(separator: ", ")))"
        case .arranged(let order, let then):
            return "\(then.logDetail) in the new page order \(order.map { String($0 + 1) }.joined(separator: ", "))"
        }
    }

    /// What the banner adds for a copy that also took the dragged order — "the new page order, with
    /// page 2 turned 90° right". `nil` for every other tool, whose copy's name says it all.
    var arrangedDetail: String? {
        guard case .arranged(_, let then) = self else { return nil }
        switch then {
        case .rotate(let pages, let turns):
            return "the new page order, with \(EditorPDFCopyName.pageList(pages)) turned \(EditorPDFCopyName.degrees(turns))"
        case .deletePages(let pages):
            return "the new page order, without \(EditorPDFCopyName.pageList(pages.sorted()))"
        default:
            return "the new page order"
        }
    }

    /// A drawn signature, or words in the script face — a typed signature or initials. The Text
    /// tool never draws in the script face.
    static func isSigned(_ item: FillSignItem) -> Bool {
        switch item.content {
        case .signature: return true
        case .text(let text): return text.isScript
        case .patch: return false
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
        return (pages.count == 1 ? "page " : "pages ") + runs(pages, dash: "–")
    }

    /// "3–5, 1" — one-based runs, in the order given. One loop for the copy's name (an en dash) and
    /// the page field's prefill (a hyphen, which `PageRangeParser` reads).
    static func runs(_ pages: [Int], dash: String) -> String {
        guard let first = pages.first else { return "" }
        var runs: [String] = []
        var start = first, end = first
        func close() { runs.append(start == end ? "\(start + 1)" : "\(start + 1)\(dash)\(end + 1)") }
        for page in pages.dropFirst() {
            if page == end + 1 { end = page } else { close(); start = page; end = page }
        }
        close()
        return runs.joined(separator: ", ")
    }

    /// Quarter turns as 0…3 — one rule for the refusal, the log and the toolkit's own arithmetic.
    static func quarterTurns(_ turns: Int) -> Int { ((turns % 4) + 4) % 4 }

    static func degrees(_ quarterTurns: Int) -> String {
        switch Self.quarterTurns(quarterTurns) {
        case 1: return "90° right"
        case 2: return "180°"
        case 3: return "90° left"
        default: return "0°"
        }
    }

    /// The longest name a copy takes: the volume's 255, less room for the keep-both rule's " 99".
    ///
    /// **Counted in UTF-16 units of the DECOMPOSED name, because that is the name this writer sends.**
    /// The volume's limit is 255 UTF-16 units of the name as written — measured 2026-10-17 on APFS:
    /// 255 "é" written as they are succeed and 256 fail; 100 CJK characters (300 UTF-8 bytes)
    /// succeed. But the path reaches `createNew` through `URL(fileURLWithPath:).path`
    /// (`FileSyncManager.generateUniqueURL`), and that DECOMPOSES it — each "é" becomes e plus its
    /// accent, two units — so through this path 127 "é" write and 128 fail. Counting the name as
    /// typed would pass a name the write then refuses with ENAMETOOLONG.
    static let longestName = 255 - 3

    static func nameLength(_ name: String) -> Int { name.decomposedStringWithCanonicalMapping.utf16.count }

    /// `<base> (<suffix>).pdf` beside `original` — the base shortened, a whole character at a time,
    /// when the name would pass ``longestName``: an original whose name was already near the limit
    /// otherwise had no copy at all, since every name the keep-both rule tried was too long.
    ///
    /// **A name that already says it is not told again** (TE190): signing "Lease (signed).pdf", or
    /// "Lease (signed) 2.pdf", wants "Lease (signed).pdf", and the keep-both rule then takes the
    /// next free number — rather than "Lease (signed) (signed).pdf".
    static func firstChoice(for original: String, suffix: String) -> String {
        let folder = (original as NSString).deletingLastPathComponent
        var base = withoutSuffix(((original as NSString).lastPathComponent as NSString).deletingPathExtension, suffix)
        let tail = " (\(suffix)).pdf"
        while !base.isEmpty, nameLength(base + tail) > longestName { base.removeLast() }
        return (folder as NSString).appendingPathComponent(base + tail)
    }

    /// `base` without a closing " (<suffix>)" or " (<suffix>) N" — the word, and the keep-both
    /// rule's number after it. Either spelling of Delete's word counts as the word: deleting one page
    /// from "Lease (pages removed).pdf" wants "Lease (page removed).pdf", not "… (pages removed)
    /// (page removed).pdf".
    static func withoutSuffix(_ base: String, _ suffix: String) -> String {
        var rest = Substring(base)
        if let space = rest.lastIndex(of: " "), case let number = rest[rest.index(after: space)...],
           !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), rest[..<space].hasSuffix(")") {
            rest = rest[..<space]
        }
        for spelling in spellings(suffix) {
            let word = " (\(spelling))"
            if rest.hasSuffix(word), rest.count > word.count { return String(rest.dropLast(word.count)) }
        }
        return base
    }

    /// The spellings `suffix` goes by: itself, and for Delete's word — alone or after the reorder's
    /// ("reordered, page removed") — its other count.
    static func spellings(_ suffix: String) -> [String] {
        let (one, many) = (EditorPDFTool.pageRemoved, EditorPDFTool.pagesRemoved)
        for (said, other) in [(one, many), (many, one)] where suffix == said || suffix.hasSuffix(", " + said) {
            return [suffix, String(suffix.dropLast(said.count)) + other]
        }
        return [suffix]
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
        var errorDescription: String? {
            "every name for the copy beside it is taken — move or rename some of its copies, then try again"
        }
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
        try writeStamped(data, besides: original, suffix: suffix, chooseName: chooseName).path
    }

    /// The same, with the stamp of the file it created — so a run cancelled while the copy was
    /// being written can take back exactly that file, and nothing that has replaced it since.
    nonisolated static func writeStamped(
        _ data: Data, besides original: String, suffix: String,
        chooseName: (URL, Set<String>) -> URL = { FileSyncManager.generateUniqueURL(for: $0, reserved: $1) }
    ) throws -> (path: String, stamp: EditorFileStore.Stamp) {
        try writeStamped(data, wanting: EditorPDFCopyName.firstChoice(for: original, suffix: suffix),
                         chooseName: chooseName)
    }

    /// The same write, at `wanted` or the keep-both rule's next free name after it — Save as PDF's
    /// door, whose first choice is the original's own name with `.pdf` rather than a suffixed one.
    nonisolated static func write(
        _ data: Data, wanting wanted: String,
        chooseName: (URL, Set<String>) -> URL = { FileSyncManager.generateUniqueURL(for: $0, reserved: $1) }
    ) throws -> String {
        try writeStamped(data, wanting: wanted, chooseName: chooseName).path
    }

    nonisolated static func writeStamped(
        _ data: Data, wanting wanted: String,
        chooseName: (URL, Set<String>) -> URL = { FileSyncManager.generateUniqueURL(for: $0, reserved: $1) }
    ) throws -> (path: String, stamp: EditorFileStore.Stamp) {
        let wanted = URL(fileURLWithPath: wanted)
        var refused: Set<String> = []
        for _ in 0..<attempts {
            let path = chooseName(wanted, refused).path
            do {
                let stamp = try EditorFileStore.createNew(data, atPath: path)
                return (path, stamp)
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

    /// Called from the lane. `progress` reaches only Compress; `isCancelled` reaches Compress, and
    /// a combined run between its two steps. `staging` is where a two-step run keeps its middle
    /// bytes — a private folder, never the PDF's own.
    nonisolated static func output(of tool: EditorPDFTool, input: URL,
                                   staging: URL = FileManager.default.temporaryDirectory,
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
        case .fillAndSign(let items, let pictures):
            let filled = try PDFToolkit.fillAndSignData(inputURL: input, items: items)
            guard !pictures.isEmpty else { return .bytes(filled) }
            // **Then the chosen pages made pictures** (decision AK): the toolkit's redaction with
            // no marks, rasterizing just those pages, so the words their patches cover go from the
            // copy. It reads by URL, so the filled bytes are staged as `.arranged`'s are.
            if isCancelled?() == true { throw CancellationError() }
            let folder = staging.appendingPathComponent("SyncCloud-pdf-tool-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let middle = folder.appendingPathComponent("staged.pdf")
            try filled.write(to: middle, options: .withoutOverwriting)
            // 4000 px on the longest side: the toolkit's own default for a redacted page.
            let options = PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 4000,
                                                    forceRasterizePages: Set(pictures))
            return .bytes(try PDFToolkit.redactData(inputURL: middle, marks: [], options: options))
        case .fillForm(let values, let items):
            return .bytes(try PDFToolkit.fillFormData(inputURL: input, values: values, items: items))
        case .arranged(let order, let then):
            // **The tool first, on the original, then the reorder** — so Rotate and Delete keep
            // their own refusals (a restricted file) and Delete its bookmark pruning, and the copy
            // is what Save Reordered Copy would make of the tool's copy.
            //
            // The toolkit reads by URL, so the middle bytes go to a folder of this run's own under
            // `staging` — never beside the PDF, where a sync or a listing would see them — and the
            // folder goes on every way out. Both steps take this one lane turn.
            guard case .bytes(let first) = try output(of: then, input: input, staging: staging,
                                                      progress: nil, isCancelled: nil)
            else { throw PDFOperationError.couldNotEncodeOutput }
            if isCancelled?() == true { throw CancellationError() }
            let folder = staging.appendingPathComponent("SyncCloud-pdf-tool-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let middle = folder.appendingPathComponent("staged.pdf")
            try first.write(to: middle, options: .withoutOverwriting)
            return .bytes(try PDFToolkit.reorderData(inputURL: middle, order: Self.order(order, after: then)))
        }
    }

    /// `order` — a permutation of the ORIGINAL's pages — as it reads in `tool`'s copy: unchanged
    /// for Rotate, which keeps every page where it was; for Delete, the survivors renumbered, in
    /// the order the reader dragged them.
    nonisolated static func order(_ order: [Int], after tool: EditorPDFTool) -> [Int] {
        guard case .deletePages(let pages) = tool else { return order }
        let gone = Set(pages)
        let survivors = order.indices.filter { !gone.contains($0) }
        let at = Dictionary(uniqueKeysWithValues: survivors.enumerated().map { ($1, $0) })
        return order.compactMap { at[$0] }
    }

    /// The run, through the lane. `perform` takes a closure that cannot throw, so the outcome
    /// crosses back as a `Result`.
    ///
    /// **`unchanged` is checked in the lane turn itself**, as the toolkit is about to read: a run
    /// can wait a long while for its turn behind a duplicate scan or a pane's Compress, and a file
    /// replaced in that wait was read afresh — Rotate turned the new file's page 2, Fill & Sign
    /// put its items by the old pages' boxes. A file that no longer has that stamp throws
    /// ``ChangedOnDisk`` and nothing is read. So is a file **evicted in that wait** — eviction keeps
    /// the stamp, and the toolkit opening the placeholder would download it inside the lane:
    /// ``CloudOnly``.
    static func run(_ tool: EditorPDFTool, input: URL,
                    staging: URL = FileManager.default.temporaryDirectory,
                    unchanged: (path: String, stamp: EditorFileStore.Stamp)? = nil,
                    isCloudOnly: (@Sendable (String) -> Bool)? = nil,
                    turnStarted: (@Sendable () -> Void)? = nil,
                    progress: (@Sendable (Int, Int) -> Void)? = nil,
                    isCancelled: (@Sendable () -> Bool)? = nil) async -> Result<Output, any Error> {
        await PDFKitSerialAccess.perform {
            turnStarted?()
            if let unchanged, EditorFileStore.stamp(ofPath: unchanged.path) != unchanged.stamp {
                return .failure(ChangedOnDisk())
            }
            if isCloudOnly?(input.path) == true { return .failure(CloudOnly()) }
            return Result { try output(of: tool, input: input, staging: staging, progress: progress, isCancelled: isCancelled) }
        }
    }

    /// The file a run was asked about changed before its lane turn came — see ``run(_:input:staging:unchanged:isCloudOnly:turnStarted:progress:isCancelled:)``.
    struct ChangedOnDisk: Error {}

    /// The file went cloud-only before the run's lane turn came — see ``run(_:input:staging:unchanged:isCloudOnly:turnStarted:progress:isCancelled:)``.
    struct CloudOnly: Error {}

    /// What a run needs to know about a file before it offers anything — read in the lane the way
    /// ``EditorPDFDocument``'s load reads it, for a run started from a pane's menu, where no
    /// document was opened first.
    enum Probe: Sendable, Equatable {
        case unreadable
        case facts(pageCount: Int, encryption: PDFEncryptionState, droppedParts: [PDFToolkit.DroppedCatalogPart] = [])
    }

    static func probe(_ input: URL) async -> Probe {
        await PDFKitSerialAccess.perform { probeInLane(input) }
    }

    /// Called from the lane. A file locked to open has no pages to count until it is unlocked —
    /// Edit attaches it at zero pages too. The protection comes off the document just opened, as
    /// Edit's open reads it, not from a second parse of the file.
    nonisolated static func probeInLane(_ input: URL) -> Probe {
        guard let document = PDFDocument(url: input) else { return .unreadable }
        if document.isLocked { return .facts(pageCount: 0, encryption: .lockedToOpen) }
        return .facts(pageCount: document.pageCount, encryption: EditorPDFDocument.encryption(of: document),
                      droppedParts: PDFToolkit.droppedCatalogParts(in: document))
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
            if EditorPDFCopyName.quarterTurns(turns) == 0 { return "A full turn leaves every page as it is." }
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
        case .fillAndSign(let items, let pictures):
            // The toolkit throws both; said here first so the lane never runs for them.
            guard items.contains(where: \.hasInk) else { return PDFOperationError.noFillSignItems.errorDescription }
            return outOfRange(items.map(\.pageIndex) + pictures, pageCount: pageCount)
        case .fillForm(let values, let items):
            let inked = items.filter(\.hasInk)
            guard !values.isEmpty || !inked.isEmpty else { return reason(PDFOperationError.noFormValues, tool: tool) }
            return outOfRange(inked.map(\.pageIndex), pageCount: pageCount)
        case .arranged(let order, let then):
            guard isPermutation(order, pageCount: pageCount) else {
                return "The new order has to name every page exactly once."
            }
            return refusal(then, pageCount: pageCount)
        case .compress, .cleanMetadata, .protect, .removePassword:
            return nil
        }
    }

    // MARK: The toolkit's refusals, in Edit's words

    /// **What the reader is told when the toolkit refuses** — every `PDFOperationError`, in one
    /// exhaustive switch so a case a new toolkit adds fails to build here rather than reaching the
    /// banner unread. Most read as the toolkit words them. Those written for PDF Utils' windows do
    /// not: `permissionsForbidEditing`, `encryptedInput` and `metadataEncrypted` send the reader to a
    /// "Password Protect → Remove password" SyncCloud has no such menu for — a restricted file's
    /// Rotate and Delete, from Edit and from a pane's batch, said so — and for a form being filled
    /// the question is the owner's form-entry or comment permission; and `textOnRotatedPage` points
    /// at a Fill & Sign that flattens, which in Edit is this very tool. `couldNotOpen` and
    /// `incorrectPassword` read as PDF Utils words them, "Could not open PDF: X" (TE186).
    ///
    /// `name` is the file the reader opened — the toolkit's URL names a link's target.
    static func reason(_ error: PDFOperationError, tool: EditorPDFTool, name opened: String? = nil) -> String {
        switch error {
        case .couldNotOpen(let url):
            return "Couldn’t open “\(opened ?? url.lastPathComponent)” — it may be damaged."
        case .incorrectPassword:
            return opened.map(EditorPDFDocument.wrongPasswordMessage) ?? "That password didn’t open this PDF. Try again."
        case .permissionsForbidEditing(let url):
            let name = opened ?? url.lastPathComponent
            guard case .fillForm(let values, _) = tool else {
                return "“\(name)”’s owner doesn’t allow changing its pages. \(liftRestrictionsStep)"
            }
            return values.isEmpty
                ? "“\(name)”’s owner allows filling its form but not adding text or signatures to its pages, "
                    + "so only the fields can be saved."
                : "“\(name)”’s owner doesn’t allow filling its form. \(EditorPDFFillSign.removePasswordStep)"
        case .textOnRotatedPage(let page):
            return "Typed text can’t go on page \(page) while the form stays fillable, because that page is rotated. "
                + "Remove it, or sign there with a drawn signature instead."
        case .encryptedInput(let url):
            return "“\(opened ?? url.lastPathComponent)” needs a password to open. PDF Tools ▸ Remove Password… writes an "
                + "unlocked copy, which this tool can then use."
        case .metadataEncrypted:
            return "This PDF is password-protected, so its metadata can’t be cleaned. \(removePasswordStep)"
        case .formValueNotAccepted(let field, let value):
            // The toolkit's words, but a paragraph typed into a field is not quoted whole.
            let shown = value.count > 40 ? value.prefix(40) + "…" : Substring(value)
            return "The field “\(field)” does not accept “\(shown)”."
        case .couldNotWrite, .outputMatchesInput, .invalidPageRange, .pageOutOfBounds,
             .pageRangeRequired, .cannotRemoveEveryPage, .fileAccessDenied, .noInputFiles, .noPagesSelected,
             .compressionFailed, .emptyPDF, .noRedactions, .redactionFailed, .watermarkTextRequired,
             .watermarkImageRequired, .watermarkFailed, .noFillSignItems, .fillSignFailed, .passwordRequired,
             .notEncrypted, .protectionFailed, .couldNotOpenImage,
             .cropTooSmall, .ocrFailed, .couldNotEncodeOutput, .noFormValues,
             .unknownFormField, .formFieldReadOnly, .formFieldNotFillable, .formFillFailed:
            return error.errorDescription ?? ""
        }
    }

    /// What to do about an owner's restriction — the one menu both Edit and the panes have.
    static let removePasswordStep = "PDF Tools ▸ Remove Password… can write an unrestricted copy if you know the password."
    /// The same for a file whose owner only restricted it: Remove Password… asks for no password
    /// there (TE167).
    static let liftRestrictionsStep = "PDF Tools ▸ Remove Password… writes a copy without the restrictions."

    /// A run's failure as the banner says it: the toolkit's refusal in Edit's words, anything else
    /// as its own description.
    static func reason(_ error: any Error, tool: EditorPDFTool, name: String? = nil) -> String {
        if let error = error as? PDFOperationError { return reason(error, tool: tool, name: name) }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// **The same failure as the log says it — with nothing the reader typed and no field's name.**
    /// The form refusals carry both (`formValueNotAccepted` quotes the value), and the log keeps to
    /// what Fill & Sign's log has always kept to: counts and the file.
    static func logReason(_ error: any Error, tool: EditorPDFTool, name: String? = nil) -> String {
        switch error as? PDFOperationError {
        case .formValueNotAccepted?: return "a field did not accept its value"
        case .unknownFormField?: return "a value named a field the form does not have"
        case .formFieldReadOnly?: return "a value was for a read-only field"
        case .formFieldNotFillable?: return "a value was for a field that cannot be filled"
        case .formFillFailed?: return "a field did not take its new value"
        default: return reason(error, tool: tool, name: name)
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
