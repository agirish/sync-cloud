import SwiftUI
import UniformTypeIdentifiers

/// The one file-type glyph vocabulary: an SF Symbol for the medium plus an identity tint per kind,
/// shared by every lens row that leads with the kind of file (Storage's ranked lists, Duplicates'
/// group rows). A shape reads as document, photo, audio or video at 17pt, where a shrunken raster
/// icon reads as a rectangle.
///
/// The tints are identity, not semantics: like `ProviderHue`, they name a category and are not
/// drawn from `SemanticColor`'s tiers even where the hue matches (a red PDF glyph is not an error).
enum FileTypeGlyph {

    /// The mediums the vocabulary distinguishes. Everything else stays a quiet generic doc: an
    /// unknown extension must not invent a colorful category. `CaseIterable` so the tests' sweeps
    /// (one shape and one legible tint per kind) can't miss a case.
    enum Kind: Equatable, CaseIterable {
        case pdf, image, audio, video, wordProcessing, spreadsheet, presentation, archive
        case folder, generic
    }

    /// Pure classification by lowercased extension, through UTType conformance (no disk I/O). The
    /// word-processing set is listed by extension because no UTType covers "a written document"
    /// without plain data.
    nonisolated static func classify(ext: String, isDirectory: Bool) -> Kind {
        if isDirectory { return .folder }
        let ext = ext.lowercased()
        if ext.isEmpty { return .generic }
        if ["doc", "docx", "pages", "rtf", "odt", "txt", "md"].contains(ext) { return .wordProcessing }
        guard let type = UTType(filenameExtension: ext), type.isDeclared else { return .generic }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .spreadsheet) || ext == "csv" || ext == "tsv" || ext == "numbers" {
            return .spreadsheet
        }
        if type.conforms(to: .presentation) || ext == "key" { return .presentation }
        if type.conforms(to: .archive) { return .archive }
        return .generic
    }

    /// The SF Symbol for a kind. Filled variants so the tint carries at row-glyph sizes. Every kind
    /// draws a different shape, so tint is never the only difference: a reader who can't tell red
    /// from blue must still tell a PDF from a Word file.
    nonisolated static func symbol(for kind: Kind) -> String {
        switch kind {
        case .pdf:            return "doc.text.fill"
        case .image:          return "photo.fill"
        case .audio:          return "music.note"
        case .video:          return "film.fill"
        case .wordProcessing: return "doc.richtext.fill"
        case .spreadsheet:    return "tablecells.fill"
        case .presentation:   return "rectangle.inset.filled"
        case .archive:        return "archivebox.fill"
        case .folder:         return "folder.fill"
        case .generic:        return "doc.fill"
        }
    }

    /// The identity tint, or nil for kinds that stay in secondary ink (generic files and plain
    /// folders): the point is to make distinct mediums findable, not to paint every row.
    ///
    /// ## Measured against the card fill, dark and light
    ///
    /// The surface is `NSColor.controlBackgroundColor`, which `lensCard` fills with (and
    /// `groundedGlassCard` in light and at Solid); the floor is the 3:1 a meaningful graphic needs.
    /// In dark at Frosted and Clear, `glassPanelGround` is tuned so no glyph reads worse than here.
    /// Contrast of each tint against that fill:
    ///
    /// | kind | dark | light |
    /// |---|---|---|
    /// | pdf | 3.25 | 5.13 |
    /// | image | 3.91 | 4.26 |
    /// | audio | 4.00 | 4.17 |
    /// | video | 3.16 | 5.27 |
    /// | wordProcessing | 3.21 | 5.19 |
    /// | spreadsheet | 3.83 | 4.35 |
    /// | presentation | 5.37 | 3.10 |
    /// | archive | 4.06 | 4.11 |
    ///
    /// Every one clears 3:1 in both appearances, so none goes through `ChromeInk`, which would
    /// flatten it to `.primary` in dark. The margins are thin: `video`, `wordProcessing` (dark) and
    /// `presentation` (light) are one nudge from failing. `FileTypeGlyphContrastTests` recomputes
    /// this against the live system colours, so a tint edited past the floor fails there.
    ///
    /// Not covered: a heavy Tint-slider wash makes a dark card much lighter, and these tints lose
    /// most of their separation. That is the wash's problem (it takes `.secondary` and the accent
    /// down too, the case `ChromeInk` handles), not fixable one tint at a time.
    nonisolated static func tint(for kind: Kind) -> Color? {
        switch kind {
        case .pdf:            return Color(red: 0.76, green: 0.25, blue: 0.25)
        case .image:          return Color(red: 0.54, green: 0.41, blue: 0.79)
        case .audio:          return Color(red: 0.12, green: 0.54, blue: 0.54)
        case .video:          return Color(red: 0.35, green: 0.38, blue: 0.79)
        case .wordProcessing: return Color(red: 0.18, green: 0.42, blue: 0.78)
        case .spreadsheet:    return Color(red: 0.16, green: 0.54, blue: 0.31)
        case .presentation:   return Color(red: 0.83, green: 0.49, blue: 0.20)
        case .archive:        return Color(red: 0.55, green: 0.48, blue: 0.40)
        case .folder, .generic: return nil
        }
    }

    /// Classification, cached by lowercased extension: `classify` is a Launch Services lookup,
    /// cheap alone but paid per row per render without this (as with `FileIconCache`). Bounded by
    /// distinct extensions; folders bypass it.
    @MainActor
    private static var kindCache: [String: Kind] = [:]

    @MainActor
    static func cachedKind(name: String, isDirectory: Bool) -> Kind {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if let cached = kindCache[ext] { return cached }
        let kind = classify(ext: ext, isDirectory: false)
        kindCache[ext] = kind
        return kind
    }

    /// The ready-made row glyph: symbol in its tint (secondary when the kind has none),
    /// hierarchical rendering, sized by the caller's frame.
    @MainActor
    @ViewBuilder
    static func view(name: String, isDirectory: Bool, pointSize: CGFloat) -> some View {
        let kind = cachedKind(name: name, isDirectory: isDirectory)
        Image(systemName: symbol(for: kind))
            .scaledFont(.system(size: pointSize))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint(for: kind).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
    }
}
