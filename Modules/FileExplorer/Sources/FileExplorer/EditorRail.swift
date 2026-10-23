import Foundation
import Sync

/// One row of the editor's file rail.
public struct EditorRailEntry: Identifiable, Equatable, Sendable {

    /// Which section of the Files tab the row is drawn in, and which of Edit's two models opens it.
    public enum Kind: Sendable {
        /// Opened as text, through `BoundedTextRead` — so its size cap applies.
        case text
        /// Opened read-only through PDFKit (``EditorPDFDocument``) — no text read, so no text cap.
        case pdf
    }

    public var path: String
    public var name: String
    public var size: Int
    public var isCloudOnly: Bool
    public var kind: Kind
    /// ``size`` in the words the row shows.
    ///
    /// **Stored, because `FileSyncManager.formatBytes` builds a `ByteCountFormatter` per call** and
    /// the rail asked it once per visible row per body pass — and a body pass happens on every
    /// keystroke in the document beside it. The rows are built off the main actor by
    /// ``EditorRail/entries(in:showsHidden:fileManager:isCloudOnly:)``, so that is where the
    /// formatting is paid, once per row per listing.
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

    /// Bigger than the editor is willing to read — **a text file only.** The cap is
    /// `BoundedTextRead`'s, and a PDF never goes through it: Edit hands a PDF to PDFKit, where a
    /// 40 MB scan is an ordinary file and opens like any other. Dimming one for the text cap would
    /// mark a file as unopenable that opens on the click.
    public var isTooLarge: Bool { kind == .text && size > BoundedTextRead.maxBytes }

    /// Whether the row is drawn dim — it can be shown, but opening it will not produce a document.
    ///
    /// **Listed and dimmed rather than filtered out**, which is the whole point of the row: a file
    /// that is simply missing from the rail reads as a bug in the rail, while a dim row with a
    /// reason on it is an answer. The reasons are the cheap ones — a `stat`'s size and its
    /// placeholder flag. Being binary is not among them, because finding that out means reading the
    /// file, so it stays a discovery at open time.
    public var isDimmed: Bool { isTooLarge || isCloudOnly }

    /// Why the row is dim, in prose, or `nil` when it is not.
    ///
    /// Worded to match `EditorFileStore.refusal(for:)`, which is what the editor shows when the
    /// same file is opened anyway — two surfaces saying the same thing about one file.
    ///
    /// A PDF has only the first reason, worded as ``EditorPDFDocument`` words its own refusal of
    /// a file that is not downloaded — the same sentence, so the row and the card agree.
    public var dimmedReason: String? {
        if isCloudOnly { return "Not downloaded — there is nothing here to read yet." }
        guard kind == .text else { return nil }
        return Self.tooLargeReason(size: size)
    }

    /// The too-large sentence, or `nil` when `size` is within what the editor will read.
    ///
    /// **One static, because two surfaces say it.** The rail's row says it here, and the source
    /// pane's row says it through `FileActionDelegate.editorRefusal` — from the app target, which
    /// cannot see `BoundedTextRead.maxBytes`. Two copies of the sentence would drift; one function
    /// cannot.
    public static func tooLargeReason(size: Int) -> String? {
        guard size > BoundedTextRead.maxBytes else { return nil }
        return EditorFileStore.tooLargeReason(bytes: size)
    }
}

/// Which of a folder's files the editor will list.
public enum EditorRail {

    /// What one look at a folder found: the rows to draw, and — when there are none — how many
    /// files are sitting in there that the rail does not list.
    public struct Survey: Equatable, Sendable {

        public var rows: [EditorRailEntry]

        /// How many files the folder holds that the rail will not open, or `nil` when the question
        /// was not asked.
        ///
        /// **Asked only when ``rows`` is empty, which is the only moment anything can show it.** A
        /// folder that lists something draws its list; this count exists for the caption that
        /// stands where the list would be, and counting it otherwise would `stat` every entry of
        /// every folder the user walks through to tell nobody anything.
        ///
        /// `nil` and `0` render the same and are deliberately different here: one is "nothing else
        /// is in there", the other is "not counted". A caller that conflates them is still correct
        /// on screen, which is why the distinction lives in the type rather than in a comment at
        /// the call site.
        public var otherFileCount: Int?

        /// The folders directly inside, by name, in Finder's order — what the folder line's menu
        /// offers to step down into (``EditorFolderTrail``). **Read off the listing's own word**,
        /// `hasDirectoryPath`, so a survey run after every autosave pays no `stat` for it; plus every
        /// link that leads to a folder — iCloud Drive's own `Desktop` and `Documents` among them.
        ///
        /// **A link is a folder by the pane's rule** (TE205): the tree walk follows a link, lists it
        /// as a folder when a folder is at the end, and drops it when nothing is — so the menu offers
        /// what the pane draws. A link lists with `hasDirectoryPath` false, which is why one to a
        /// folder used to be missing here unless it was one of iCloud Drive's two. The listing names
        /// its links at no cost per entry (`DirectoryListing.symbolicLinkPaths`), and only a link
        /// pays a `stat`, to follow it.
        public var folders: [String]

        public init(rows: [EditorRailEntry], otherFileCount: Int?, folders: [String] = []) {
            self.rows = rows
            self.otherFileCount = otherFileCount
            self.folders = folders
        }
    }

    /// The text-like files and PDFs directly inside `folder`, in the order the rail draws them.
    ///
    /// **One level, no recursion.** The rail answers "what can I open in the folder I am standing
    /// in"; a recursive list would answer a different question and would walk a tree on every
    /// selection change in the sidebar.
    ///
    /// Directories are not rows — a folder row here would be a second, weaker way to change folder
    /// that lands somewhere the pane does not agree with. They are offered instead by the folder
    /// line's menu, which moves the pane itself (``Survey/folders``).
    public static func entries(in folder: String,
                        showsHidden: Bool,
                        fileManager: FileManaging = FileManager.default,
                        isCloudOnly: (String) -> Bool = {
                            MaterializationStatus.isCloudOnly(atPath: $0)
                        }) -> [EditorRailEntry] {
        survey(in: folder, showsHidden: showsHidden, fileManager: fileManager,
               isCloudOnly: isCloudOnly).rows
    }

    /// ``entries``, plus the count that answers the question an empty rail used to get wrong.
    ///
    /// **A folder full of files Edit does not open is not an empty folder, and the rail said it
    /// was.** The list keeps `PairContentKind.text` and `.pdf`, so standing in a folder of Word
    /// documents or photos drew "No text files in this folder" — true, and indistinguishable on
    /// screen from a folder with nothing in it at all. The count is what lets the caption tell
    /// those two apart. (A folder of scans used to be the example; PDFs are listed now.)
    ///
    /// **The second pass runs only for a folder that listed nothing**, so the ordinary case pays
    /// nothing for it: it re-walks names already in hand, and the `stat` per name is the price of
    /// keeping directories out of the count. Counting them would put a second wrong answer where
    /// the first one was — "none of the 12 files" over a folder holding eight subfolders and four
    /// files.
    ///
    /// **Listed through Sync's shared `listing(of:)`**, which asks a folder whose contents are not on
    /// this Mac through the dataless-folder reads: when its cloud app is not running, the bare
    /// `contentsOfDirectory` this used to call never returned, and the rail re-lists after every
    /// autosave — one more stuck thread each time. Such a folder now reads as unreadable, after at
    /// most the reads' deadline and only the first time; the rail's refresh asks through
    /// ``surveySuspending(in:showsHidden:fileManager:)``, which does not hold a thread for even that.
    public static func survey(in folder: String,
                       showsHidden: Bool,
                       fileManager: FileManaging = FileManager.default,
                       isCloudOnly: (String) -> Bool = {
                           MaterializationStatus.isCloudOnly(atPath: $0)
                       }) -> Survey {
        // Unreadable, or no folder at all: "there are no other files in it" is a claim, and there
        // is nothing here to base one on. `nil` says that; `0` would assert it.
        guard !folder.isEmpty else { return Survey(rows: [], otherFileCount: nil) }
        let listing = fileManager.listing(of: URL(fileURLWithPath: folder),
                                          includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard listing.outcome != .unreadable else { return Survey(rows: [], otherFileCount: nil) }
        let names = listing.urls.map(\.lastPathComponent)
        let symbolicLinks = listing.symbolicLinkPaths ?? []
        // The pane's own rule for hidden — a leading dot — so the menu offers what the pane lists.
        // Asked first, so a hidden link is never followed for a menu that will not show it.
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
            // **Stat'd through the link, because the rail's dim rule and the read cap have to
            // agree.** `attributesOfItem` does not follow a symlink — it reports the link's own
            // size, which is the length of the path it holds — so a link to a 40 MB file listed as
            // "30 bytes", undimmed, and was then refused as too large the moment it was clicked.
            // `BoundedTextRead` reads through `contents(atPath:)`, which follows, so resolving here
            // is what makes the row describe the file the editor will actually open.
            let target = (path as NSString).resolvingSymlinksInPath
            let attributes = try? fileManager.attributesOfItem(atPath: target)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            // Asked per row, and only for rows that survived the filters above — it is one `lstat`,
            // which is cheap enough per visible row but not cheap enough per directory entry.
            rows.append(EditorRailEntry(path: path, name: name, size: size,
                                        isCloudOnly: isCloudOnly(path), kind: kind))
        }
        // Localized standard order, so "note 2" sorts before "note 10" and the rail reads the way
        // Finder does rather than the way ASCII does.
        let sorted = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard sorted.isEmpty else { return Survey(rows: sorted, otherFileCount: nil, folders: folders) }

        var others = 0
        for name in names {
            guard showsHidden || !name.hasPrefix(".") else { continue }
            // Every name that gets this far is neither text nor a PDF — had one been either,
            // existed, and not been a directory, it would be a row and this pass would not be
            // running. So the directory check is the only question left to ask.
            let path = (folder as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            others += 1
        }
        return Survey(rows: [], otherFileCount: others, folders: folders)
    }

    /// ``survey(in:showsHidden:fileManager:isCloudOnly:)`` for a caller that can suspend — the
    /// rail's own refresh. A folder whose contents are not on this Mac is asked for first, through
    /// `waitForContents`, without holding a thread while its cloud app answers or does not; the
    /// survey's listing then never waits — an answered folder is on disk, an unanswered one is
    /// refused at once.
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

    /// The Files tab's sections — **Text Files, then PDFs, each in the order it was handed** (the
    /// survey's Finder order, after any filter), and **a section with no rows is left out**: a
    /// "PDFs" heading over nothing would read as a list that failed to load.
    ///
    /// Sections and not one interleaved list because the two open into different things — one a
    /// document you can type into, the other a read-only reader — and the rail is where the choice
    /// is made. The ⌘N naming row is not a row here: it is drawn above the list, so no rule about
    /// empty sections can hide it (``EditorFileRailView``).
    static func sections(_ entries: [EditorRailEntry]) -> [Section] {
        [EditorRailEntry.Kind.text, .pdf].compactMap { kind in
            let rows = entries.filter { $0.kind == kind }
            return rows.isEmpty ? nil : Section(kind: kind, rows: rows)
        }
    }

    /// The rows that match what was typed into the rail's filter.
    ///
    /// **Substring, case- and diacritic-insensitive, over the name only.** Not the path: every row
    /// in the rail is in the same folder, so a path match would be a folder-name match that hits
    /// every row at once or none — a filter that answers "all or nothing" is not a filter.
    ///
    /// A filter of only whitespace is no filter. Somebody who has typed a space and stopped is
    /// mid-thought, and answering "no files" to that is a rail that appears to have emptied itself.
    static func filtered(_ entries: [EditorRailEntry], matching filter: String) -> [EditorRailEntry] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
