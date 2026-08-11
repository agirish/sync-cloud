import SwiftUI
import UniformTypeIdentifiers

/// The one file-type glyph vocabulary (v4.0 polish P7): a medium-symbol SF glyph plus an
/// identity tint per kind of file, shared by every lens row that leads with "what kind of
/// thing is this" — Storage's ranked lists and the Duplicates group rows.
///
/// **Symbols name the medium where a letter or a raster icon can't be consistent.** Storage
/// drew every file as the same gray `doc.fill` while Duplicates drew NSWorkspace's raster
/// icons — two surfaces, one file, two vocabularies. A shape says *document / photo / audio /
/// video* at 17pt where a shrunken raster thumbnail says mostly "rectangle".
///
/// **The tints are identity, not semantics.** Like `ProviderHue` and the treemap's palette,
/// these hues identify a category; they are deliberately not drawn from `SemanticColor`'s
/// tiers even where the hue coincides (a red PDF glyph is not an error). Context carries the
/// difference: these lead a row as iconography, tiers color claims.
enum FileTypeGlyph {

    /// The mediums the vocabulary distinguishes. Everything else stays a quiet generic doc —
    /// an unknown extension must not invent a colorful category.
    enum Kind: Equatable {
        case pdf, image, audio, video, wordProcessing, spreadsheet, presentation, archive
        case folder, generic
    }

    /// Pure classification by lowercased path extension. UTType conformance does the heavy
    /// lifting (metadata-only, no disk I/O); the word-processing set is by extension because
    /// there is no single UTType umbrella for "a written document" that excludes plain data.
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

    /// The SF Symbol for a kind. Filled variants so the tint carries at row-glyph sizes.
    nonisolated static func symbol(for kind: Kind) -> String {
        switch kind {
        case .pdf:            return "doc.text.fill"
        case .image:          return "photo.fill"
        case .audio:          return "music.note"
        case .video:          return "film.fill"
        case .wordProcessing: return "doc.text.fill"
        case .spreadsheet:    return "tablecells.fill"
        case .presentation:   return "rectangle.inset.filled"
        case .archive:        return "archivebox.fill"
        case .folder:         return "folder.fill"
        case .generic:        return "doc.fill"
        }
    }

    /// The identity tint, or nil for the kinds that stay in secondary ink (generic files and
    /// plain folders — the vocabulary's job is to make *distinct* mediums findable, not to
    /// paint every row).
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

    /// Classification, cached by lowercased extension. `classify` is a Launch Services
    /// metadata lookup — cheap alone, but paid per row per render pass without this, which is
    /// the cost `FileIconCache` exists to remove one shelf over. Bounded by the number of
    /// distinct extensions on screen; directories bypass it (no lookup to save).
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
