import Foundation
import Sync

/// One row of the editor's file rail.
public struct EditorRailEntry: Identifiable, Equatable, Sendable {

    /// Which section of the Files tab the row is drawn in, and which of Edit's two models opens it.
    public enum Kind: Sendable {
        /// Opened as text, through `BoundedTextRead`, so its size cap applies.
        case text
        /// Opened read-only through PDFKit (``EditorPDFDocument``): no text read, so no text cap.
        case pdf
    }

    public var path: String
    public var name: String
    public var size: Int
    public var isCloudOnly: Bool
    public var kind: Kind
    /// ``size`` in the words the row shows. Stored, because `FileSyncManager.formatBytes` builds a
    /// `ByteCountFormatter` per call and the rail redraws on every keystroke in the document beside
    /// it. The rows are built off the main actor by
    /// ``EditorRail/entries(in:showsHidden:fileManager:isCloudOnly:)``, once per row per listing.
    public var sizeCaption: String

    public init(path: String, name: String, size: Int, isCloudOnly: Bool, kind: Kind = .text) {
        self.path = path
        self.name = name
        self.size = size
        self.isCloudOnly = isCloudOnly
        self.kind = kind
        self.sizeCaption = FileSyncManager.formatBytes(size)
    }

    public var id: String { path }

    /// Bigger than the editor will read; a text file only. The cap is `BoundedTextRead`'s, and a
    /// PDF goes to PDFKit, where a 40 MB scan opens like any other, so dimming one would mark as
    /// unopenable a file that opens on the click.
    public var isTooLarge: Bool { kind == .text && size > BoundedTextRead.maxBytes }

    /// Whether the row is drawn dim: shown, but opening it won't produce a document. Listed and
    /// dimmed rather than filtered out, because a missing file reads as a bug in the rail while a
    /// dim row with a reason is an answer. Only cheap reasons count (a `stat`'s size and placeholder
    /// flag); being binary needs a read, so it is found at open time.
    public var isDimmed: Bool { isTooLarge || isCloudOnly }

    /// Why the row is dim, in prose, or `nil` when it isn't. Worded to match
    /// `EditorFileStore.refusal(for:)`, what the editor shows when the file is opened anyway. A PDF
    /// has only the first reason, in ``EditorPDFDocument``'s words, so the row and the card agree.
    public var dimmedReason: String? {
        if isCloudOnly { return "Not downloaded — there is nothing here to read yet." }
        guard kind == .text else { return nil }
        return Self.tooLargeReason(size: size)
    }

    /// The too-large sentence, or `nil` when `size` is within what the editor will read. One static
    /// because two surfaces say it: the rail's row, and the source pane's row through
    /// `FileActionDelegate.editorRefusal` in the app target, which can't see
    /// `BoundedTextRead.maxBytes`.
    public static func tooLargeReason(size: Int) -> String? {
        guard size > BoundedTextRead.maxBytes else { return nil }
        return EditorFileStore.tooLargeReason(bytes: size)
    }
}

/// Which of a folder's files the editor will list.
public enum EditorRail {

    /// What one look at a folder found: the rows to draw and, when there are none, how many files
    /// are in there that the rail doesn't list.
    public struct Survey: Equatable, Sendable {

        public var rows: [EditorRailEntry]

        /// How many files the folder holds that the rail won't open, or `nil` when not asked. Asked
        /// only when ``rows`` is empty, the only time the caption shows it; counting otherwise would
        /// `stat` every entry of every folder walked through. `0` means "nothing else is in there",
        /// `nil` "not counted"; they render the same.
        public var otherFileCount: Int?

        /// The folders directly inside, by name, in Finder's order: what the folder line's menu
        /// offers to step into (``EditorFolderTrail``). Read off the listing's `hasDirectoryPath`, so
        /// a survey after every autosave pays no `stat`, plus every link that leads to a folder
        /// (iCloud Drive's `Desktop` and `Documents` among them).
        ///
        /// A link is a folder by the pane's rule, so the menu offers what the pane draws: followed,
        /// and a folder when a folder is at the end. Links list with `hasDirectoryPath` false; the
        /// listing names them for free (`DirectoryListing.symbolicLinkPaths`), and only a link pays a
        /// `stat`, to follow it.
        public var folders: [String]

        public init(rows: [EditorRailEntry], otherFileCount: Int?, folders: [String] = []) {
            self.rows = rows
            self.otherFileCount = otherFileCount
            self.folders = folders
        }
    }

    /// The text-like files and PDFs directly inside `folder`, in the order the rail draws them.
    ///
    /// One level, no recursion: the rail answers "what can I open in this folder", and recursion
    /// would walk a tree on every sidebar selection. Directories aren't rows, since a folder row
    /// would be a weaker way to change folder that the pane disagrees with; the folder line's menu
    /// offers them and moves the pane itself (``Survey/folders``).
    public static func entries(in folder: String,
                        showsHidden: Bool,
                        fileManager: FileManaging = FileManager.default,
                        isCloudOnly: (String) -> Bool = {
                            MaterializationStatus.isCloudOnly(atPath: $0)
                        }) -> [EditorRailEntry] {
        survey(in: folder, showsHidden: showsHidden, fileManager: fileManager,
               isCloudOnly: isCloudOnly).rows
    }

    /// ``entries``, plus a count of the other files, so a folder of files Edit doesn't open (Word
    /// documents, photos) isn't captioned like an empty one.
    ///
    /// The count's pass runs only for a folder that listed nothing, re-walking names in hand; its
    /// `stat` per name keeps directories out, or "none of the 12 files" could mean eight subfolders.
    ///
    /// Listed through Sync's shared `listing(of:)`, which reads a folder whose contents aren't on
    /// this Mac through the dataless-folder reads: a bare `contentsOfDirectory` never returns when
    /// its cloud app isn't running, and the rail re-lists after every autosave. Such a folder reads
    /// as unreadable after at most the reads' deadline; the rail's refresh asks through
    /// ``surveySuspending(in:showsHidden:fileManager:)``, which holds no thread even for that.
    public static func survey(in folder: String,
                       showsHidden: Bool,
                       fileManager: FileManaging = FileManager.default,
                       isCloudOnly: (String) -> Bool = {
                           MaterializationStatus.isCloudOnly(atPath: $0)
                       }) -> Survey {
        // Unreadable, or no folder at all: nothing to base a count on, so `nil`; `0` would claim
        // there are no other files.
        guard !folder.isEmpty else { return Survey(rows: [], otherFileCount: nil) }
        let listing = fileManager.listing(of: URL(fileURLWithPath: folder),
                                          includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard listing.outcome != .unreadable else { return Survey(rows: [], otherFileCount: nil) }
        let names = listing.urls.map(\.lastPathComponent)
        let symbolicLinks = listing.symbolicLinkPaths ?? []
        // The pane's own rule for hidden (a leading dot), so the menu offers what the pane lists.
        // Asked first, so a hidden link is never followed for a menu that won't show it.
        let folders = listing.urls
            .filter { showsHidden || !$0.lastPathComponent.hasPrefix(".") }
            .filter { url in
                if url.hasDirectoryPath { return true }
                // The walk's rule for a link (`stat(at:)` in the pane's scan): followed, a folder
                // when a folder is at the end; a dangling link, or one to a file, is not a folder.
                guard symbolicLinks.contains(url.path) else { return false }
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var rows: [EditorRailEntry] = []
        for name in names {
            guard showsHidden || !name.hasPrefix(".") else { continue }
            let kind: EditorRailEntry.Kind
            switch PairContentKind.classify(path: name) {
            case .text: kind = .text
            case .pdf: kind = .pdf
            case .image, .other: continue
            }
            let path = (folder as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            // Stat'd through the link, so the rail's dim rule and the read cap agree:
            // `attributesOfItem` reports a symlink's own size, so a link to a 40 MB file would list
            // undimmed and then be refused on click, while `BoundedTextRead` follows the link. The
            // cloud answer is the target's for the same reason: a link is always local, so asking
            // about it would draw a link to a cloud-only file undimmed, with no Download.
            let target = MaterializationStatus.linkTarget(of: path)
            let attributes = try? fileManager.attributesOfItem(atPath: target)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            // Asked only for rows that survived the filters above: one `lstat` is cheap enough per
            // row but not per directory entry.
            rows.append(EditorRailEntry(path: path, name: name, size: size,
                                        isCloudOnly: isCloudOnly(target), kind: kind))
        }
        // Localized standard order, so "note 2" sorts before "note 10", as in Finder.
        let sorted = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard sorted.isEmpty else { return Survey(rows: sorted, otherFileCount: nil, folders: folders) }

        var others = 0
        for name in names {
            guard showsHidden || !name.hasPrefix(".") else { continue }
            // Any text or PDF file would have been a row and this pass wouldn't run, so the
            // directory check is the only question left.
            let path = (folder as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            others += 1
        }
        return Survey(rows: [], otherFileCount: others, folders: folders)
    }

    /// ``survey(in:showsHidden:fileManager:isCloudOnly:)`` for a caller that can suspend: the rail's
    /// own refresh. A folder whose contents aren't on this Mac is asked for first through
    /// `waitForContents`, holding no thread while its cloud app answers or doesn't, so the listing
    /// never waits: an answered folder is on disk, an unanswered one is refused at once.
    public static func surveySuspending(in folder: String,
                                        showsHidden: Bool,
                                        fileManager: FileManaging = FileManager.default) async -> Survey {
        // Not for "": `URL(fileURLWithPath:)` makes that the working directory.
        if !folder.isEmpty {
            _ = await fileManager.waitForContents(of: URL(fileURLWithPath: folder))
        }
        return survey(in: folder, showsHidden: showsHidden, fileManager: fileManager)
    }

    /// One section of the Files tab: which kind it holds, and its rows.
    struct Section: Equatable, Identifiable {
        let kind: EditorRailEntry.Kind
        let rows: [EditorRailEntry]
        var id: EditorRailEntry.Kind { kind }

        var title: String {
            switch kind {
            case .text: return "Text Files"
            case .pdf: return "PDFs"
            }
        }
    }

    /// The Files tab's sections: Text Files, then PDFs, each in the order handed (the survey's
    /// Finder order, after any filter). A section with no rows is left out, since a heading over
    /// nothing reads as a failed load. Sections, not one list, because the two open into different
    /// things: a document to type into and a read-only reader. The ⌘N naming row is drawn above the
    /// list, so no empty-section rule can hide it (``EditorFileRailView``).
    static func sections(_ entries: [EditorRailEntry]) -> [Section] {
        [EditorRailEntry.Kind.text, .pdf].compactMap { kind in
            let rows = entries.filter { $0.kind == kind }
            return rows.isEmpty ? nil : Section(kind: kind, rows: rows)
        }
    }

    /// The rows that match what was typed into the rail's filter.
    ///
    /// Substring, case- and diacritic-insensitive, over the name only: every row is in the same
    /// folder, so a path match would hit all rows or none. A filter of only whitespace is no filter,
    /// so typing a space doesn't seem to empty the rail.
    static func filtered(_ entries: [EditorRailEntry], matching filter: String) -> [EditorRailEntry] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
