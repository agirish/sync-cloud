import Foundation
import Sync
import SwiftUI

/// **What Save as PDF can turn into a PDF**, by the file's extension — and which engine does it
/// (``SaveAsPDFRender``).
///
/// Written down rather than read off `UTType`, for `PairContentKind`'s reason: this decides whether
/// a menu item appears, and an umbrella type would offer whatever a given Mac decides conforms.
/// Only the kinds an engine here was measured on.
public enum SaveAsPDFKind: String, Equatable, Sendable, CaseIterable {
    /// `.txt` — set in the editor's own face by ``DocumentPDF``, the pages Edit's Print makes.
    case text
    /// `.md`, `.markdown` — Edit's rendered preview, through ``DocumentPDF``.
    case markdown
    /// `.rtf` — Apple's text system, paginated by AppKit's print system.
    case richText
    /// `.docx`, `.doc` — Quick Look's page, printed by WebKit; the text system when Quick Look
    /// gives nothing.
    case word
    /// `.xlsx`, `.xls` — Quick Look's sheets, printed by WebKit, one after another.
    case spreadsheet
    /// `.pptx`, `.ppt` — Quick Look's slides, one page each.
    case presentation

    static let byExtension: [String: SaveAsPDFKind] = [
        "txt": .text,
        "md": .markdown, "markdown": .markdown,
        "rtf": .richText,
        "docx": .word, "doc": .word,
        "xlsx": .spreadsheet, "xls": .spreadsheet,
        "pptx": .presentation, "ppt": .presentation,
    ]

    /// The kind for a path, or `nil` when nothing here converts it.
    ///
    /// **`~$` names are Office's lock files**, not documents: Word writes one beside every file it
    /// has open, a few hundred bytes of owner name with a `.docx` extension. Quick Look reads none of
    /// them, so offering one would only ever fail.
    public static func of(path: String) -> SaveAsPDFKind? {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("~$") else { return nil }
        return byExtension[(name as NSString).pathExtension.lowercased()]
    }
}

/// **What a row's menu offers to save as PDF, or `nil` for no item at all** — hidden rather than
/// greyed, as PDF Tools is (``PanePDFToolOffer``), and on the same three rules: any folder, any
/// file nothing here can convert (a PDF among them — it keeps PDF Tools), or any cloud-only file
/// hides it. A cloud-only row already offers Download, and an engine would have no bytes to read.
///
/// **File ▸ Save as PDF asks the same question**, through ``forSelection(_:)``, and greys where the
/// row hides.
public enum SaveAsPDFOffer: Equatable, Sendable {
    case single(path: String)
    case several(paths: [String])

    public var paths: [String] {
        switch self {
        case .single(let path): return [path]
        case .several(let paths): return paths
        }
    }

    /// The item's name, on the row and in File ▸ — a batch counts its files, in the words PDF Tools
    /// counts them in ("PDF Tools · 3 files"), so the two items read as a pair (TE130).
    public var title: String {
        switch self {
        case .single: return "Save as PDF"
        case .several(let paths): return "Save as PDF · \(paths.count) files"
        }
    }

    /// **The row menu's answer, and File ▸ Save as PDF's.** The cloud lookup is the row's own — the
    /// badge's memo, else an `lstat` — and a batch's answer is the one PDF Tools holds for the same
    /// selection (``PanePDFSelectionCloud``), so the two items ask the filesystem once between them.
    @MainActor
    public static func forSelection(_ nodes: [FileNode]) -> SaveAsPDFOffer? {
        if nodes.count > 1 {
            let paths = nodes.map(\.id)
            return offer(for: nodes, isCloudOnly: { _ in
                PanePDFSelectionCloud.anyCloudOnly(paths, isCloudOnly: FileContextMenu.isCloudOnly)
            })
        }
        return offer(for: nodes, isCloudOnly: FileContextMenu.isCloudOnly)
    }

    /// The cheap rules first — a flag the node holds and path math — so a selection with a folder or
    /// a JPEG in it never pays a cloud lookup.
    static func offer(for nodes: [FileNode], isCloudOnly: (String) -> Bool) -> SaveAsPDFOffer? {
        guard !nodes.isEmpty,
              nodes.allSatisfy({ !$0.isDirectory && SaveAsPDFKind.of(path: $0.id) != nil }),
              !nodes.contains(where: { isCloudOnly($0.id) })
        else { return nil }
        if nodes.count == 1, let node = nodes.first { return .single(path: node.id) }
        return .several(paths: nodes.map(\.id))
    }
}

/// **Where a saved PDF goes: beside its original, under the original's name** — `Lease.docx`
/// becomes `Lease.pdf` in the same folder (decision AN). A name already taken gets the app's one
/// keep-both rule, `FileSyncManager.generateUniqueURL` — `Lease 2.pdf`, as Finder names it — and
/// the write itself refuses anything that appears in between (``EditorPDFCopyWriter``).
enum SaveAsPDFName {
    /// `<base>.pdf` beside `original`, the base shortened a whole character at a time when the name
    /// would pass the volume's limit — counted as ``EditorPDFCopyName`` counts, in the decomposed
    /// UTF-16 the write sends.
    static func firstChoice(for original: String) -> String {
        let folder = (original as NSString).deletingLastPathComponent
        var base = ((original as NSString).lastPathComponent as NSString).deletingPathExtension
        if base.isEmpty { base = "Document" }
        let tail = ".pdf"
        while base.count > 1, EditorPDFCopyName.nameLength(base + tail) > EditorPDFCopyName.longestName {
            base.removeLast()
        }
        return (folder as NSString).appendingPathComponent(base + tail)
    }

    /// Whether a PDF can be written into the original's folder at all — asked before a render, so a
    /// read-only folder asks where to save instead (``PaneSaveAsPDF``).
    static func folderIsWritable(for original: String, fileManager: FileManager = .default) -> Bool {
        fileManager.isWritableFile(atPath: (original as NSString).deletingLastPathComponent)
    }
}
