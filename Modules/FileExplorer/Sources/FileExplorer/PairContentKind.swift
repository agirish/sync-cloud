import Foundation
import UniformTypeIdentifiers

/// What kind of viewer a compared pair gets.
///
/// **Not the same question `FileTypeGlyph.classify` answers, and that is why it is a second
/// type.** That one names a *medium* for a row's icon — audio, video, archive, presentation — and
/// has ten cases because a list wants ten distinguishable shapes. This one names a *pair viewer*,
/// and there are only as many cases as there are viewers built. A PDF and a Word document are two
/// mediums and one answer here (`.other`, until something can page a `.docx`), while a `.txt` and
/// a `.md` are one medium there and one answer here.
///
/// **`.other` is the honest majority and is not a failure.** Every kind falls back to two
/// independent Quick Look panes, which is what phase 1 shipped for everything — still the whole
/// win over a 40pt thumbnail. What a typed viewer adds is synchronised scrolling and the visual
/// diff modes, and those are only worth building where the format has a page or a canvas to
/// synchronise.
enum PairContentKind: String, Equatable, CaseIterable {
    /// Two `PDFView`s, page- and scroll-synchronised, with the pixel diff modes.
    case pdf
    /// Two scroll-hosted image views, zoom-synchronised, with the pixel diff modes.
    case image
    /// A bounded, encoding-tolerant text read and a side-by-side diff (phase 3).
    case text
    /// Two independent Quick Look panes, and a caption saying they do not scroll together.
    case other

    /// Pure classification by lowercased path extension.
    ///
    /// **An explicit extension list for text, in the style `FileTypeGlyph.classify` documents**: no
    /// `UTType` umbrella means "a file whose bytes are lines a person reads". `.public.text`
    /// conformance would pull in every source format, `.json`, `.xml` — which is fine, they ARE
    /// diffable — but it also pulls in `.rtf` and `.webarchive`, which are not lines at all and
    /// would render as one long line of markup. So the list is written down, and everything else
    /// takes `.other`, where a Quick Look pane renders it correctly.
    ///
    /// PDF and image go through `UTType` conformance, which is metadata-only and does no I/O: those
    /// two families are genuinely open-ended (`heic`, `arw`, `cr3` and whatever a camera ships
    /// next), and a hand-written list of them is the thing that silently stops covering a format.
    nonisolated static func classify(ext: String) -> PairContentKind {
        let ext = ext.lowercased()
        guard !ext.isEmpty else { return .other }
        if Self.textExtensions.contains(ext) { return .text }
        guard let type = UTType(filenameExtension: ext), type.isDeclared else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return .other
    }

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

    /// Whether this kind gets a synchronised pair viewer at all. `.other` and `.text` do not: one
    /// has no canvas to synchronise and the other synchronises by line, in its own pane.
    var hasSyncedViewer: Bool { self == .pdf || self == .image }

    /// Whether the pixel diff modes (swipe, onion, difference) apply. Same set as
    /// ``hasSyncedViewer`` today — they need a raster of the same region on both sides, which is
    /// exactly what a synced viewer is — but a separate member, because a future kind could get one
    /// without the other and a shared `Bool` would make that unwriteable.
    var hasPixelModes: Bool { self == .pdf || self == .image }

    /// The caption a pane wears when nothing synchronises it, so the surface never pretends. nil
    /// when the panes really are in step.
    var unsyncedCaption: String? {
        switch self {
        case .pdf, .image, .text: return nil
        case .other: return "These previews scroll on their own — Quick Look has no scroll to synchronise."
        }
    }
}
