import Foundation
import UniformTypeIdentifiers

/// N2 Automations — the rule model. An automation is a small, readable sentence a user authors once:
/// *when a loose file matches these on-device conditions, it belongs in this folder.* This first
/// version is **preview-only** — the model and evaluator produce a dry run of what *would* happen;
/// nothing is moved. Every condition is answered by a local signal (path, filename glob, UTType,
/// file size, modification date, or on-device text) so a rule is deterministic, private, and free —
/// no Claude Cloud classifier is ever consulted on the automation path.

// MARK: - File kind

/// A coarse file family a rule can match, derived purely from the file's extension via `UTType`
/// (offline, deterministic). Deliberately coarse — the palette offers "kind is an image", not a
/// long UTI list — because that is what a person reasons about.
public enum FileKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case image, pdf, video, audio, archive, document

    public var id: String { rawValue }

    /// User-facing label, also used to resolve the `{kind}` destination token.
    public var label: String {
        switch self {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .video: return "Video"
        case .audio: return "Audio"
        case .archive: return "Archive"
        case .document: return "Document"
        }
    }

    /// The UTTypes this kind is satisfied by. A file matches when the type derived from its
    /// extension conforms to any of these.
    var matchingTypes: [UTType] {
        switch self {
        case .image: return [.image]
        case .pdf: return [.pdf]
        case .video: return [.movie, .video, .audiovisualContent]
        case .audio: return [.audio]
        case .archive: return [.archive, .gzip, .zip]
        // "Document" is the common office/text family, minus PDF (which has its own kind).
        case .document: return [.plainText, .rtf, .spreadsheet, .presentation,
                                UTType("com.microsoft.word.doc") ?? .text,
                                UTType("org.openxmlformats.wordprocessingml.document") ?? .text,
                                .text]
        }
    }

    /// Whether a file with the given extension is of this kind. Extension-driven so it stays pure
    /// (no disk access) and works even for evicted cloud files whose bytes aren't local.
    public func matches(fileExtension ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return false }
        return matchingTypes.contains { type.conforms(to: $0) }
    }

    /// The kind of a file name, or nil when the extension maps to nothing recognized. `.pdf` is
    /// checked before `.document` so a PDF resolves to "PDF", not the broader "Document".
    public static func of(fileName: String) -> FileKind? {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        for kind in [FileKind.image, .pdf, .video, .audio, .archive, .document] where kind.matches(fileExtension: ext) {
            return kind
        }
        return nil
    }
}

// MARK: - Condition

/// One on-device test a rule can apply to a file. Combined with ``AutomationRule/MatchMode``
/// (all/any). Every case is answerable locally; ``requiresContent`` marks the one case that needs
/// the file's text read (PDFKit / Vision OCR / plain text), so the evaluator only pays that cost
/// when a rule actually asks for it.
public enum AutomationCondition: Sendable, Equatable, Codable, Hashable {
    /// The file's immediate parent folder is named this (case-insensitive). "Location".
    case folderNamed(String)
    /// The file name matches this shell glob (`*`, `?`), case-insensitive. Reuses ``IgnoreRules``.
    case nameMatches(String)
    /// The file is of this coarse kind (by extension → UTType).
    case kindIs(FileKind)
    /// The file is larger than this many megabytes.
    case largerThanMB(Int)
    /// The file hasn't been modified in at least this many days ("untouched").
    case untouchedForDays(Int)
    /// The file's on-device text contains this term (case-insensitive substring of the extracted
    /// excerpt). The only content-reading condition.
    case contentContains(String)

    /// True for conditions that need the file's text extracted. Used to defer the expensive read.
    public var requiresContent: Bool {
        if case .contentContains = self { return true }
        return false
    }

    /// A plain-words description for the rule summary and editor, e.g. "in a folder named Downloads".
    public var summary: String {
        switch self {
        case .folderNamed(let name):
            return "in a folder named \(name.isEmpty ? "…" : name)"
        case .nameMatches(let glob):
            return "name matches \(glob.isEmpty ? "…" : glob)"
        case .kindIs(let kind):
            return "kind is \(kind.label)"
        case .largerThanMB(let mb):
            return "larger than \(mb) MB"
        case .untouchedForDays(let days):
            return "not modified in \(days) day\(days == 1 ? "" : "s")"
        case .contentContains(let term):
            return "text contains “\(term.isEmpty ? "…" : term)”"
        }
    }

    /// Whether the condition is fully specified (a blank glob / term / zero threshold is a
    /// half-built condition the editor shouldn't let the user save).
    public var isComplete: Bool {
        switch self {
        case .folderNamed(let s), .nameMatches(let s), .contentContains(let s):
            return !s.trimmingCharacters(in: .whitespaces).isEmpty
        case .largerThanMB(let n): return n > 0
        case .untouchedForDays(let n): return n > 0
        case .kindIs: return true
        }
    }

    /// A stable key for the condition's *type* (not its value) — lets the editor offer a type
    /// picker and swap the associated value while keeping the row.
    public var kindKey: String {
        switch self {
        case .folderNamed: return "folderNamed"
        case .nameMatches: return "nameMatches"
        case .kindIs: return "kindIs"
        case .largerThanMB: return "largerThanMB"
        case .untouchedForDays: return "untouchedForDays"
        case .contentContains: return "contentContains"
        }
    }
}

// MARK: - Rule

/// A single automation. `destinationTemplate` is **provider-relative** (e.g.
/// `Documents/Invoices/{year}`) — resolved against whichever provider root the preview runs over —
/// so a rule is portable across providers rather than pinned to one absolute path (unlike
/// ``FilingRule``, which stores an absolute, provider-scoped destination).
public struct AutomationRule: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var id: UUID
    /// A short human name, e.g. "Invoices". Labels the rule everywhere it appears.
    public var name: String
    /// A disabled rule is kept (so the user's work isn't lost) but skipped by the preview.
    public var enabled: Bool
    /// Whether every condition must hold (`all`) or just one (`any`).
    public var matchMode: MatchMode
    public var conditions: [AutomationCondition]
    /// Provider-relative destination folder, may contain tokens (see ``AutomationEvaluator``).
    public var destinationTemplate: String

    public enum MatchMode: String, Codable, Sendable, CaseIterable, Identifiable {
        case all, any
        public var id: String { rawValue }
        /// The connector shown between conditions, e.g. "all of" / "any of".
        public var label: String { self == .all ? "all of" : "any of" }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        matchMode: MatchMode = .all,
        conditions: [AutomationCondition] = [],
        destinationTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchMode = matchMode
        self.conditions = conditions
        self.destinationTemplate = destinationTemplate
    }

    /// A rule is runnable only when it has a name, at least one complete condition, and a
    /// destination — a half-built rule is saved (so edits aren't lost) but never previews.
    public var isRunnable: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !destinationTemplate.trimmingCharacters(in: .whitespaces).isEmpty
            && conditions.contains { $0.isComplete }
    }

    /// True when any (complete) condition reads file text — the preview then fetches a snippet.
    public var requiresContent: Bool {
        conditions.contains { $0.requiresContent && $0.isComplete }
    }

    /// A one-line plain-words summary, e.g. "PDF · text contains “invoice” → Documents/Invoices/{year}".
    public var summary: String {
        let parts = conditions.filter { $0.isComplete }.map { $0.summary }
        let lhs: String
        if parts.isEmpty {
            lhs = "any file"
        } else if parts.count == 1 {
            lhs = parts[0]
        } else {
            lhs = "\(matchMode.label): " + parts.joined(separator: " · ")
        }
        let dest = destinationTemplate.isEmpty ? "…" : destinationTemplate
        return "\(lhs) → \(dest)"
    }
}
