import AppKit
import PDFKit

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

    var displayMode: PDFDisplayMode {
        switch self {
        case .singlePage: return .singlePage
        case .continuous: return .singlePageContinuous
        case .twoPages: return .twoUp
        case .twoPagesContinuous: return .twoUpContinuous
        }
    }

    /// The layout a PDFKit display mode is — the inverse of ``displayMode``.
    init(_ mode: PDFDisplayMode) {
        switch mode {
        case .singlePage: self = .singlePage
        case .twoUp: self = .twoPages
        case .twoUpContinuous: self = .twoPagesContinuous
        default: self = .continuous
        }
    }

    public var isTwoUp: Bool { self == .twoPages || self == .twoPagesContinuous }
    public var isContinuous: Bool { self == .continuous || self == .twoPagesContinuous }

    /// What PDFKit's `displaysAsBook` is for this layout: the cover choice, which means nothing
    /// until there are two pages to a row.
    func displaysAsBook(coverSeparately: Bool) -> Bool { isTwoUp && coverSeparately }

    /// **The pages on screen together with `page`**, zero-based — the page alone in a single-page
    /// layout, else its spread: 1–2, 3–4 … or, with the cover on its own, 1, then 2–3, 4–5 …, the
    /// pairing PDFKit draws (measured 2026-10-17: `goToNextPage` from page 1 lands in 2–3 with the
    /// cover separate, 3–4 without). A last odd page stands alone.
    static func spread(containing page: Int, pageCount: Int, twoUp: Bool, coverSeparately: Bool) -> ClosedRange<Int> {
        guard pageCount > 0 else { return 0...0 }
        let page = min(max(page, 0), pageCount - 1)
        guard twoUp else { return page...page }
        let first: Int
        if coverSeparately {
            if page == 0 { return 0...0 }
            first = page - (page - 1) % 2
        } else {
            first = page - page % 2
        }
        return first...min(first + 1, pageCount - 1)
    }
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

    static func layout(in defaults: UserDefaults) -> EditorPDFLayout {
        defaults.string(forKey: layoutKey).flatMap(EditorPDFLayout.init(rawValue:)) ?? layoutDefault
    }

    static func coverSeparately(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: coverSeparatelyKey) as? Bool ?? coverSeparatelyDefault
    }

    /// **Where the page and zoom capsule floats** (Phase 6a) — stored as the place's name, never as
    /// points, so it survives a resize and a relaunch at any window size. Bottom centre until it is
    /// moved, and again after Reset Position or a double-click on its grip.
    public static let capsulePlaceKey = "editorPDFCapsulePlace"
    public static let capsulePlaceDefault = EditorPDFCapsulePlace.bottom

    static func capsulePlace(in defaults: UserDefaults) -> EditorPDFCapsulePlace {
        defaults.string(forKey: capsulePlaceKey).flatMap(EditorPDFCapsulePlace.init(rawValue:)) ?? capsulePlaceDefault
    }

    /// **Where Fill & Sign's palette floats** (Phase 6b, mockup F) — the capsule's eight places,
    /// stored the same way under its own key. The middle of the left side until it is moved, as
    /// Acrobat's palette sits.
    public static let palettePlaceKey = "editorPDFPalettePlace"
    public static let palettePlaceDefault = EditorPDFCapsulePlace.leading

    static func palettePlace(in defaults: UserDefaults) -> EditorPDFCapsulePlace {
        defaults.string(forKey: palettePlaceKey).flatMap(EditorPDFCapsulePlace.init(rawValue:)) ?? palettePlaceDefault
    }
}

/// **The zoom's ladder and its words** (mockup 15).
///
/// − and + step through ``presets``, the menu's own stops, so the buttons and the menu never
/// disagree about where the next zoom is. A pinch is free to land between stops or past either end
/// (within `EditorPDFViewState.minScale`…`maxScale`), and the next step from there goes to the stop
/// beyond it in that direction.
public enum EditorPDFZoom {
    public static let presets: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 4]

    /// A scale as the label says it — whole percents, which is also what decides whether a scale is
    /// ON a stop: 124.6% is 125%, and + from there goes to 150%.
    static func percentValue(_ scale: CGFloat) -> Int { Int((scale * 100).rounded()) }

    public static func percent(_ scale: CGFloat) -> String { "\(percentValue(scale))%" }

    /// The stop after `scale` in that direction, or `nil` past the last one — what disables + at
    /// 400% and − at 50%.
    static func step(from scale: CGFloat, in zoomingIn: Bool) -> CGFloat? {
        let here = percentValue(scale)
        return zoomingIn ? presets.first { percentValue($0) > here }
                         : presets.last { percentValue($0) < here }
    }

    /// The control's label: the fit while one holds the page, the percentage otherwise — so a
    /// pinch says 137%. Actual Size says 100%: it is a scale, and the 100% stop is ticked for it.
    public static func label(fit: EditorPDFFit?, scale: CGFloat) -> String {
        switch fit {
        case .page?: return "Fit Page"
        case .width?: return "Fit Width"
        case .actual?, nil: return percent(scale)
        }
    }

    /// The preset to tick, or `nil` — none while Fit Page or Fit Width holds the page (theirs is
    /// ticked instead), and none for a scale between stops.
    static func tickedPreset(fit: EditorPDFFit?, scale: CGFloat) -> CGFloat? {
        if fit == .page || fit == .width { return nil }
        return presets.first { percentValue($0) == percentValue(scale) }
    }
}
