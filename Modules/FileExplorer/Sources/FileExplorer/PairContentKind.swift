import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Whether the Edit workspace opens this path, and as what.
///
/// A public window onto ``PairContentKind``, which is internal, so the Info inspector (Dashboard)
/// and the File menu (MacApp) ask the same gate the row menu applies in
/// ``SharedFileMenuItems/openInEditor(_:delegate:)``. A re-typed extension list would drift, and
/// a door would offer a file the editor refuses, or withhold one it would open.
///
/// Pure and I/O-free: it reads the path's extension and nothing else, so it is safe inside a
/// `body` or a menu item's `disabled(…)`.
///
/// **It can't tell a folder from a file**: a directory named `notes.md` answers true. A caller that
/// can hold a directory tests that itself, as the row menu's `!singleNode.isDirectory` does.
public enum EditableText {
    /// Whether the editor opens this file as a read-only PDF (``EditorPDFDocument``, not the text
    /// document). The host routes on it before any text read is attempted.
    public static func isPDF(path: String) -> Bool {
        PairContentKind.classify(path: path) == .pdf
    }

    /// Whether "Open in Edit" is offered for this file: text, which opens writable, or a PDF,
    /// which opens read-only. The gate every door asks: ⌘O, the row menu, the preview's button,
    /// a click in Edit's pane, the inspector, row dimming, a Compare difference row and a duplicate
    /// copy.
    public static func opensInEdit(path: String) -> Bool {
        let kind = PairContentKind.classify(path: path)
        return kind == .text || kind == .pdf
    }

    /// The extensions themselves, lowercased, for the one reader that can't ask per path:
    /// `ExternalOpenClaimTests`, which checks that every one of them is a kind of text macOS
    /// recognises (and so is offered by the app's `public.text` claim in Finder's Open With), or is
    /// one of the few the claim's comment in `project.yml` names as not offered.
    public static var extensions: Set<String> { PairContentKind.textExtensions }
}

/// What kind of viewer a compared pair gets.
///
/// Not `FileTypeGlyph.classify`'s question: that names a medium for a row's icon, with a shape per
/// medium. This names a pair viewer, with only as many cases as there are viewers built; a `.docx`
/// is `.other` here until something can page it.
///
/// `.other` is the honest majority, not a failure: two independent Quick Look panes. A typed
/// viewer adds synchronised scrolling and the visual diff modes, worth building only where the
/// format has a page or a canvas to synchronise.
enum PairContentKind: String, Equatable, CaseIterable {
    /// Two `PDFView`s, page- and scroll-synchronised, with the pixel diff modes.
    case pdf
    /// Two scroll-hosted image views, zoom-synchronised, with the pixel diff modes.
    case image
    /// A bounded, encoding-tolerant text read and a side-by-side diff.
    case text
    /// Two independent Quick Look panes, and a caption saying they do not scroll together.
    case other

    /// Pure classification by lowercased path extension.
    ///
    /// Text is an explicit extension list, as in `FileTypeGlyph.classify`: no `UTType` umbrella
    /// means "lines a person reads". `public.text` conformance would also pull in `.rtf` and
    /// `.webarchive`, which would render as one long line of markup. Everything else takes
    /// `.other`, where Quick Look renders it correctly.
    ///
    /// PDF and image go through `UTType` conformance, metadata-only with no I/O, because those
    /// families are open-ended (`heic`, `arw`, `cr3`, the next camera's) and a hand-written list
    /// would silently stop covering a format.
    nonisolated static func classify(ext: String) -> PairContentKind {
        let ext = ext.lowercased()
        guard !ext.isEmpty else { return .other }
        if Self.textExtensions.contains(ext) { return .text }
        guard let type = UTType(filenameExtension: ext), type.isDeclared else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        // Conforming to `.image` is not being decodable: `public.svg-image` conforms but ImageIO
        // has no codec for it, so the image viewer would show two empty views and a difference
        // mode that never finishes, while Quick Look under `.other` renders SVG well.
        if type.conforms(to: .image) { return imageIOCanDecode(type) ? .image : .other }
        return .other
    }

    /// Whether ImageIO can actually turn this type into a raster.
    ///
    /// Asked of the framework, not listed here, because the decodable set is open-ended. ImageIO is
    /// the component that governs (`PagePairRaster.renderImage` is a `CGImageSource`), so the
    /// classification and the renderer can't disagree.
    static func imageIOCanDecode(_ type: UTType) -> Bool {
        canDecode(type, listing: decodableImageTypes, resolved: decodableImageUTTypes)
    }

    /// The rule itself, against a listing supplied rather than read from the framework.
    ///
    /// The listing is a parameter so the umbrella guard in ``decodableTypes(in:)`` can be tested:
    /// the real `CGImageSourceCopyTypeIdentifiers` doesn't name `public.image`, so against it the
    /// guard never fires. Tests pass a listing that does.
    ///
    /// - Parameters:
    ///   - listing: the identifiers a decoder is claimed for, matched by name first.
    ///   - resolved: the same listing as concrete types, for a type ImageIO lists only under a
    ///     broader one it declares (some RAW families). Built once by the caller, because this runs
    ///     from a `body` (see ``decodableImageUTTypes``).
    static func canDecode(_ type: UTType, listing: Set<String>, resolved: [UTType]) -> Bool {
        if listing.contains(type.identifier) { return true }
        return resolved.contains { type.conforms(to: $0) }
    }

    /// A listing of identifiers as concrete `UTType`s, with any umbrella dropped.
    ///
    /// `public.image` is dropped deliberately: every image conforms to it, so a listing naming it
    /// would call all of them decodable, including `public.svg-image`, which ImageIO can't decode.
    static func decodableTypes(in listing: Set<String>) -> [UTType] {
        listing.compactMap { UTType($0) }.filter { $0 != .image }
    }

    /// The identifiers `CGImageSourceCopyTypeIdentifiers` reports, read once: it enumerates
    /// installed codecs, which don't change under a running app.
    private static let decodableImageTypes: Set<String> = {
        Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    }()

    /// The same list as resolved `UTType`s, built once rather than per call.
    ///
    /// `classify` runs from view code (the rail's rows, menu items' `disabled(…)`), and the
    /// conformance walk is the path for any type ImageIO doesn't list by name, such as SVG and RAW
    /// subtypes. Rebuilding every `UTType` there would be work whose answer never changes.
    private static let decodableImageUTTypes: [UTType] = decodableTypes(in: decodableImageTypes)

    static func classify(path: String) -> PairContentKind {
        classify(ext: (path as NSString).pathExtension)
    }

    /// The extensions a bounded text read is worth attempting on. Deliberately conservative: a
    /// wrong `.text` answer costs a real file the correct Quick Look rendering, while a wrong
    /// `.other` answer costs a diff nobody had before.
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "text", "log",
        "csv", "tsv",
        "json", "yaml", "yml", "toml", "ini", "conf", "cfg",
        "xml", "html", "htm", "css", "js", "ts", "swift", "py", "rb", "sh", "zsh", "bash",
        "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "go", "rs", "sql",
    ]

    /// The extensions the editor offers a rendered preview for.
    ///
    /// A subset of ``textExtensions``, spelled out for that set's reason: this decides whether a
    /// control appears, and a UTI umbrella would pull in whatever conforms to `public.plain-text`
    /// on a given machine.
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Whether this file is Markdown, and therefore has something to preview.
    static func isMarkdown(path: String) -> Bool {
        markdownExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether this kind gets a synchronised pair viewer at all. `.other` and `.text` do not: one
    /// has no canvas to synchronise and the other synchronises by line, in its own pane.
    var hasSyncedViewer: Bool { self == .pdf || self == .image }

    /// Whether the pixel diff modes (swipe, onion, difference) apply. The same set as
    /// ``hasSyncedViewer`` today, since both need a raster of one region on each side, but separate
    /// so a future kind can have one without the other.
    var hasPixelModes: Bool { self == .pdf || self == .image }

    /// The caption a pane wears when nothing synchronises it, so the surface never pretends. nil
    /// when the panes really are in step.
    var unsyncedCaption: String? {
        switch self {
        case .pdf, .image, .text: return nil
        case .other: return "These previews scroll on their own — Quick Look has no scroll to synchronize."
        }
    }
}
