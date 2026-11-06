import Foundation
import UniformTypeIdentifiers

/// The kinds a pane's type filter groups extensions under: "Images", "PDFs", "Apps & installers".
///
/// Its own table, not `FileKind`'s: `FileKind` (Automations) names a file for a rule's `{kind}`
/// token in six singular words and folds spreadsheets, slides and text into "Document". A person
/// choosing what to see needs those split out, Apps & installers apart from Archives, and plural
/// titles. `FileTypeFamilyTests` pins that the two agree wherever both answer. Case order is the
/// order the type list draws, so it is part of the contract.
public enum FileTypeFamily: String, CaseIterable, Sendable, Codable, Hashable {
    case images, pdfs, documents, spreadsheets, presentations, movies, audio
    case appsAndInstallers, archives, textAndCode, noExtension, other

    /// The row title in the type list, and the filter's summary word when the whole kind is ticked.
    public var title: String {
        switch self {
        case .images: return "Images"
        case .pdfs: return "PDFs"
        case .documents: return "Documents"
        case .spreadsheets: return "Spreadsheets"
        case .presentations: return "Presentations"
        case .movies: return "Movies"
        case .audio: return "Audio"
        case .appsAndInstallers: return "Apps & installers"
        case .archives: return "Archives"
        case .textAndCode: return "Text & code"
        case .noExtension: return "No extension"
        case .other: return "Other"
        }
    }

    /// What a folder's count pill calls `count` matches of this kind: "1 image", "2 images".
    public func countPhrase(_ count: Int) -> String {
        let one: String, many: String
        switch self {
        case .images: (one, many) = ("image", "images")
        case .pdfs: (one, many) = ("PDF", "PDFs")
        case .documents: (one, many) = ("document", "documents")
        case .spreadsheets: (one, many) = ("spreadsheet", "spreadsheets")
        case .presentations: (one, many) = ("presentation", "presentations")
        case .movies: (one, many) = ("movie", "movies")
        case .audio: (one, many) = ("audio file", "audio files")
        case .appsAndInstallers: (one, many) = ("app or installer", "apps & installers")
        case .archives: (one, many) = ("archive", "archives")
        case .textAndCode: (one, many) = ("text file", "text files")
        case .noExtension, .other: (one, many) = ("file", "files")
        }
        return "\(count.formatted()) \(count == 1 ? one : many)"
    }

    /// The extension a name is filed under: its last component, lowercased, `""` for none. So
    /// `.tar.gz` files under `gz`, and a dotfile (`.DS_Store`) has none.
    public static func fileExtension(ofName name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// The kind an extension (as `fileExtension(ofName:)` returns it) belongs to. Extension-only,
    /// so it answers for cloud-only files and the same extension always lands in the same kind.
    public static func of(extension ext: String) -> FileTypeFamily {
        if ext.isEmpty { return .noExtension }
        if let known = named[ext] { return known }
        cacheLock.lock()
        let cached = cache[ext]
        cacheLock.unlock()
        if let cached { return cached }
        let resolved = classify(ext)
        cacheLock.lock()
        cache[ext] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// Extensions whose type identifier is missing, ambiguous or misleading on a Mac without the
    /// app that owns them: `key` can resolve to a key file rather than Keynote, `pages` and
    /// `numbers` are unregistered without iWork, and `csv` conforms to `public.text`. Checked before
    /// the type system, so these never depend on what is installed.
    static let named: [String: FileTypeFamily] = {
        var table: [String: FileTypeFamily] = [:]
        let groups: [(FileTypeFamily, [String])] = [
            (.images, ["heic", "heif", "webp", "svg"]),
            (.pdfs, ["pdf"]),
            (.documents, ["doc", "docx", "pages", "rtf", "rtfd", "odt"]),
            (.spreadsheets, ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]),
            (.presentations, ["ppt", "pptx", "key", "odp"]),
            (.appsAndInstallers, ["dmg", "iso", "pkg", "mpkg", "app", "sparseimage", "sparsebundle"]),
            (.archives, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]),
            (.textAndCode, ["md", "txt", "json"]),
        ]
        for (family, extensions) in groups { for ext in extensions { table[ext] = family } }
        return table
    }()

    /// Everything not in `named`, by type conformance. Audio is asked before movies because both
    /// conform to `public.audiovisual-content`; `.movie` is the narrower question for video.
    private static func classify(_ ext: String) -> FileTypeFamily {
        guard let type = UTType(filenameExtension: ext) else { return .other }
        let order: [(FileTypeFamily, [UTType])] = [
            (.pdfs, [.pdf]),
            (.images, [.image]),
            (.audio, [.audio]),
            (.movies, [.movie]),
            (.spreadsheets, [.spreadsheet]),
            (.presentations, [.presentation]),
            (.appsAndInstallers, [.diskImage, .application, .applicationBundle]
                + [UTType("com.apple.installer-package-archive")].compactMap { $0 }),
            (.archives, [.archive]),
            (.textAndCode, [.sourceCode, .text, .json, .xml, .propertyList]),
        ]
        for (family, types) in order where types.contains(where: { type.conforms(to: $0) }) {
            return family
        }
        return .other
    }

    private static let cacheLock = NSLock()
    /// `nonisolated(unsafe)` because every access is under `cacheLock`.
    nonisolated(unsafe) private static var cache: [String: FileTypeFamily] = [:]
}
