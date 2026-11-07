import Foundation

/// **How the reader lays the pages out** — Phase 5a's four layouts, which are PDFKit's four
/// display modes under the names Preview and Acrobat give them.
///
/// Continuous is the default because it is what the reader drew before there was a choice. The
/// two-page layouts can show the first page on its own (``EditorPDFSettings/coverSeparatelyKey``),
/// so a book's spreads pair 2–3, 4–5 as they do in print — PDFKit's `displaysAsBook`.
public enum EditorPDFLayout: String, CaseIterable, Sendable {
    case singlePage
    case continuous
    case twoPages
    case twoPagesContinuous

    public var title: String {
        switch self {
        case .singlePage: return "Single Page"
        case .continuous: return "Continuous"
        case .twoPages: return "Two Pages"
        case .twoPagesContinuous: return "Two Pages, Continuous"
        }
    }

    public var isTwoUp: Bool { self == .twoPages || self == .twoPagesContinuous }
    public var isContinuous: Bool { self == .continuous || self == .twoPagesContinuous }
}

/// **The reader's remembered choices** — in ``EditorTextSettings``' style: a key and a default for
/// each, read by the view state and written when the reader picks one. The layout and the cover
/// are remembered across launches (decided 2026-10-17); the zoom deliberately is not, so every
/// PDF opens at Fit Page.
public enum EditorPDFSettings {
    public static let layoutKey = "editorPDFLayout"
    public static let layoutDefault = EditorPDFLayout.continuous

    /// **Off by default** — PDFKit's own default, and the one that pairs 1–2, which is how a
    /// letter or a report is read; a book or a magazine is where the reader turns it on.
    public static let coverSeparatelyKey = "editorPDFCoverSeparately"
    public static let coverSeparatelyDefault = false
}
