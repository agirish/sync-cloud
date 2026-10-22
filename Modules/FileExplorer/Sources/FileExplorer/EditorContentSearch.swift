import Foundation
import Darwin
import Sync

/// One line of a text file that holds what was searched for (RD38) — a row under the file's name
/// in the Files list's Contents results.
public struct EditorContentLine: Identifiable, Equatable, Sendable {
    /// 1-based, the editor's own count: `\r\n`, a lone `\r` and `\n` each end one line, as
    /// ``EditorCaret`` and ``EditorLineIndex`` count them — so the number shown is the line Go to
    /// Line lands on.
    public var line: Int
    /// 1-based, in characters, as ``EditorGoToLine/Target`` counts columns — where the match starts.
    public var column: Int
    /// The match's length in the file, in UTF-16 units: what the editor selects.
    public var length: Int
    /// The line as the row shows it — leading space dropped, and cut around the match when the line
    /// is long.
    public var snippet: String
    /// Where the match sits in ``snippet``, in UTF-16 units, for the highlight.
    public var highlight: NSRange

    public var id: Int { line }

    public init(line: Int, column: Int, length: Int, snippet: String, highlight: NSRange) {
        self.line = line
        self.column = column
        self.length = length
        self.snippet = snippet
        self.highlight = highlight
    }
}

/// One file the Contents search found (RD38): a text file with its matching lines, or a PDF, Word
/// or PowerPoint file Spotlight says contains the word.
public struct EditorContentHit: Identifiable, Equatable, Sendable {

    /// What opening it does, and which group it is listed in.
    public enum Kind: Sendable {
        /// Read here, line by line: opens in Edit at the match.
        case text
        /// From Spotlight: opens in Edit with its find bar holding the word.
        case pdf
        /// A Word or PowerPoint file, from Spotlight. Edit does not open these, so a click shows it
        /// in Quick Look.
        case document
    }

    public var path: String
    public var name: String
    /// The folder it is in, relative to the folder searched — `""` for that folder itself.
    public var subfolder: String
    public var kind: Kind
    /// The first matching lines, at most ``EditorContentSearch/Limits/linesPerFile``. Empty for a
    /// Spotlight hit, which says which files match and not where.
    public var lines: [EditorContentLine]
    /// How many lines match in all — at least `lines.count`.
    public var lineCount: Int
    /// A Spotlight hit whose content is not on this Mac. Never true for a text hit: those are
    /// skipped, unread.
    public var isCloudOnly: Bool

    public var id: String { path }

    public init(path: String, name: String, subfolder: String, kind: Kind,
                lines: [EditorContentLine] = [], lineCount: Int = 0, isCloudOnly: Bool = false) {
        self.path = path
        self.name = name
        self.subfolder = subfolder
        self.kind = kind
        self.lines = lines
        self.lineCount = lineCount
        self.isCloudOnly = isCloudOnly
    }
}

/// **Search inside files (RD38): the text half** — every text file Edit opens, in a folder and the
/// folders inside it, read directly and matched line by line.
///
/// **Read on each search, not indexed.** Measured on his Mac on 21 October: ~/Documents holds 475
/// text files, 10 MB, read in 0.1–0.2 s. An index would be a second copy of his files to keep true.
///
/// **What it never does is read a file whose content is not on this Mac.** One `lstat` per text
/// file decides it (``FileFacts``), before anything opens the file — opening an evicted iCloud file
/// is what makes the provider download it. A folder whose own listing is not on this Mac is asked
/// for through Sync's dataless-folder reads (`waitForContents`), which is how the pane lists one.
///
/// **What it skips, and says so:** files not downloaded, files over the editor's 4 MiB read cap,
/// and — silently, because they are not documents — binary files, hidden files and folders (a
/// leading dot) and packages. Hidden folders are where the volume is: ~/Projects lists 4,455 items
/// outside them and its `.claude` and `.git` folders hold tens of thousands more.
public enum EditorContentSearch {

    /// What one search may spend. The walk stops at ``entries``; reading stops once ``files`` files
    /// have matched — a word in every file would otherwise list the whole folder.
    public struct Limits: Equatable, Sendable {
        public var entries: Int
        public var files: Int
        public var linesPerFile: Int

        public init(entries: Int, files: Int, linesPerFile: Int) {
            self.entries = entries
            self.files = files
            self.linesPerFile = linesPerFile
        }

        /// 250,000 items is fifteen times ~/Documents (16,727 items outside hidden folders).
        public static let standard = Limits(entries: 250_000, files: 500, linesPerFile: 20)
    }

    /// Why a search ended before it had looked everywhere.
    public enum Stop: Equatable, Sendable {
        /// The walk met ``Limits/entries`` items.
        case entryLimit(Int)
        /// ``Limits/files`` files matched.
        case fileLimit(Int)
    }

    /// Where a search has got to.
    public struct Progress: Equatable, Sendable {
        /// Text files read so far.
        public var read: Int
        /// Text files the walk found to read — final once ``walked`` is true.
        public var found: Int
        public var walked: Bool

        public init(read: Int = 0, found: Int = 0, walked: Bool = false) {
            self.read = read
            self.found = found
            self.walked = walked
        }
    }

    /// What the finished search did not read, for the status line under the results.
    public struct Summary: Equatable, Sendable {
        public var read = 0
        public var matched = 0
        public var notDownloaded = 0
        public var tooLarge = 0
        /// Folders whose contents are not on this Mac and did not arrive when asked for.
        public var unansweredFolders = 0
        public var stop: Stop?

        public init() {}
    }

    public enum Event: Equatable, Sendable {
        /// A file that matched. `order` is its place in the walk — Finder's order, folder by folder
        /// — which is how the list stays still while results arrive out of order.
        case hit(EditorContentHit, order: Int)
        case progress(Progress)
        case finished(Summary)
    }

    // MARK: Matching

    /// The query as it is matched: trimmed, and `nil` when nothing is left.
    public static func needle(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How a line is matched — the Files list's name filter's rule (``EditorRail/filtered``), so
    /// "Cafe" finds "café" in a file as it finds it in a name.
    static let matchOptions: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The lines of `text` that contain `needle`: the first `keeping` of them, and how many there are.
    ///
    /// **One search over the whole text, not one per line.** `NSString.range(of:options:range:)`
    /// finds the next match, the line count is advanced to it over the UTF-16 units in between, and
    /// the search goes on from the end of that line — so a line is one row however often it
    /// matches, and lines with no match cost only the count.
    static func matchingLines(in text: String, needle: String,
                              keeping: Int) -> (lines: [EditorContentLine], count: Int) {
        let ns = text as NSString
        let length = ns.length
        guard length > 0, !needle.isEmpty else { return ([], 0) }
        var units = [unichar](repeating: 0, count: length)
        ns.getCharacters(&units, range: NSRange(location: 0, length: length))

        var lines: [EditorContentLine] = []
        var count = 0
        var line = 1
        var lineStart = 0
        var cursor = 0
        var from = 0
        while from < length {
            let found = ns.range(of: needle, options: matchOptions,
                                 range: NSRange(location: from, length: length - from))
            guard found.location != NSNotFound else { break }
            // Count the breaks between where the last count stopped and the match. A CR followed by
            // an LF is one break, counted at the LF.
            while cursor < found.location {
                let unit = units[cursor]
                if unit == 0x0A {
                    line += 1
                    lineStart = cursor + 1
                } else if unit == 0x0D, cursor + 1 >= length || units[cursor + 1] != 0x0A {
                    line += 1
                    lineStart = cursor + 1
                }
                cursor += 1
            }
            var lineEnd = NSMaxRange(found)
            while lineEnd < length, units[lineEnd] != 0x0A, units[lineEnd] != 0x0D { lineEnd += 1 }
            count += 1
            if lines.count < keeping {
                lines.append(contentLine(in: ns, text: text, line: line, lineStart: lineStart,
                                         lineEnd: lineEnd, match: found))
            }
            from = lineEnd
        }
        return (lines, count)
    }

    /// The longest snippet a row is handed — more than a 232pt rail can show, so the row truncates
    /// at its own width rather than here.
    static let snippetLength = 160
    /// How much of a long line is kept before the match, so the match is never cut off the row.
    static let leadBeforeMatch = 24

    private static func contentLine(in ns: NSString, text: String, line: Int, lineStart: Int,
                                    lineEnd: Int, match: NSRange) -> EditorContentLine {
        // The column in characters, as Go to Line counts it — an emoji is one column.
        let startIndex = String.Index(utf16Offset: lineStart, in: text)
        let matchIndex = String.Index(utf16Offset: match.location, in: text)
        let column = text[startIndex..<matchIndex].count + 1

        // Leading space dropped; a long lead cut to a few characters before the match, on a
        // character boundary, with an ellipsis saying so.
        var start = lineStart
        while start < match.location, let scalar = UnicodeScalar(ns.character(at: start)),
              CharacterSet.whitespaces.contains(scalar) { start += 1 }
        var prefix = ""
        if match.location - start > leadBeforeMatch {
            start = ns.rangeOfComposedCharacterSequence(at: match.location - leadBeforeMatch).location
            prefix = "…"
        }
        var end = min(lineEnd, start + snippetLength)
        if end < lineEnd { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: max(end - 1, start))) }
        end = max(end, min(NSMaxRange(match), lineEnd))
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let snippet = prefix + body
        let lead = (prefix as NSString).length + (match.location - start)
        let shown = min(match.length, (snippet as NSString).length - lead)
        return EditorContentLine(line: line, column: column, length: match.length, snippet: snippet,
                                 highlight: NSRange(location: lead, length: max(shown, 0)))
    }

    // MARK: The walk

    /// What one `lstat` says about a path — and, for a symbolic link, one `stat` of what it points
    /// at, which is what a link to a file or a folder is read or walked as.
    public struct FileFacts: Equatable, Sendable {
        public enum Kind: Sendable { case file, directory, other }
        public var kind: Kind
        /// `SF_DATALESS`: the content lives with the provider. ``MaterializationStatus`` reads the
        /// same flag.
        public var isDataless: Bool
        public var size: Int
        /// Device and inode — what a file or folder reached twice, through a link, is known by.
        public var identity: Identity
        /// A folder Finder shows as one file — an app, a bundle, a `.photoslibrary`.
        public var isPackage: Bool

        public struct Identity: Hashable, Sendable {
            public var device: Int64
            public var inode: UInt64
            public init(device: Int64, inode: UInt64) {
                self.device = device
                self.inode = inode
            }
        }

        public init(kind: Kind, isDataless: Bool, size: Int, identity: Identity, isPackage: Bool = false) {
            self.kind = kind
            self.isDataless = isDataless
            self.size = size
            self.identity = identity
            self.isPackage = isPackage
        }

        /// The real filesystem. **Metadata only**: neither call opens the file, so neither fetches
        /// an evicted one — the same promise ``MaterializationStatus/realStatFlags`` makes.
        public static let real: @Sendable (String) -> FileFacts? = { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                guard stat(path, &info) == 0 else { return nil }
            }
            let kind: Kind
            switch info.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            default: kind = .other
            }
            var isPackage = false
            if kind == .directory {
                isPackage = (try? URL(fileURLWithPath: path, isDirectory: true)
                    .resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            }
            return FileFacts(kind: kind, isDataless: MaterializationStatus.isDataless(flags: info.st_flags),
                             size: Int(info.st_size),
                             identity: Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino)),
                             isPackage: isPackage)
        }
    }

    /// One text file the walk found to read.
    struct Candidate: Sendable {
        var path: String
        var subfolder: String
        var order: Int
    }

    /// What the walk found: the files to read, in Finder's order, and what it skipped.
    struct Walk: Sendable {
        var candidates: [Candidate] = []
        var notDownloaded = 0
        var tooLarge = 0
        var unansweredFolders = 0
        var stop: Stop?
    }

    /// The folder and every folder inside it, breadth first and in Finder's order within each.
    ///
    /// **Each folder is listed on its own** (Sync's `listing(of:)`, shallow), never with one
    /// recursive enumerator: a recursive walk is how a folder whose contents are not on this Mac
    /// gets entered without being asked for, and the shallow listing asks for one through the
    /// dataless-folder reads — holding this walk's own thread for at most their deadline, and only
    /// the first time a folder goes unanswered.
    ///
    /// **A folder or file reached twice — through a symbolic link — is read once.** Below a folder
    /// link the paths are the link's spelling (`listing` re-spells under the path asked), so the
    /// same file shows up under two names; its device and inode do not change. That is also what
    /// keeps a link to a parent from walking for ever.
    static func walk(root: String, fileManager: FileManaging, facts: @Sendable (String) -> FileFacts?,
                     limits: Limits, isStopped: () -> Bool) -> Walk {
        var walk = Walk()
        guard let rootFacts = facts(root), rootFacts.kind == .directory else { return walk }
        var seenFolders: Set<FileFacts.Identity> = [rootFacts.identity]
        var seenFiles: Set<FileFacts.Identity> = []
        var queue: [(path: String, subfolder: String)] = [(root, "")]
        var entries = 0
        var head = 0
        while head < queue.count {
            if isStopped() { return walk }
            let (folder, subfolder) = queue[head]
            head += 1
            let listing = fileManager.listing(of: URL(fileURLWithPath: folder, isDirectory: true))
            if listing.isUnanswered { walk.unansweredFolders += 1 }
            let children = listing.urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            for child in children {
                entries += 1
                if entries > limits.entries {
                    walk.stop = .entryLimit(limits.entries)
                    return walk
                }
                let name = child.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                let path = (folder as NSString).appendingPathComponent(name)
                let inner = subfolder.isEmpty ? name : subfolder + "/" + name
                let isText = PairContentKind.classify(path: name) == .text
                // A real folder says so in the listing; a link says nothing until it is asked, and a
                // name with no extension may be one. Anything else is not text and not a folder.
                guard child.hasDirectoryPath || isText || (name as NSString).pathExtension.isEmpty
                else { continue }
                guard let fact = facts(path) else { continue }
                switch fact.kind {
                case .directory:
                    guard !fact.isPackage, seenFolders.insert(fact.identity).inserted else { continue }
                    queue.append((path, inner))
                case .file:
                    guard isText, seenFiles.insert(fact.identity).inserted else { continue }
                    if fact.isDataless {
                        walk.notDownloaded += 1
                    } else if fact.size > BoundedTextRead.maxBytes {
                        walk.tooLarge += 1
                    } else {
                        walk.candidates.append(Candidate(path: path, subfolder: subfolder,
                                                         order: walk.candidates.count))
                    }
                case .other:
                    continue
                }
            }
        }
        return walk
    }

    // MARK: The search

    /// How many files are read at once — the duplicate hasher's number (`hashFilesCounting`).
    static let maxConcurrentReads = 6

    /// Set once, read from every reader: whether the search has been dropped.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// Searches the text files in `root` and its folders for `query`, streaming each file that
    /// matches as soon as it has been read.
    ///
    /// **On threads of its own, never Swift's cooperative pool.** Every step here blocks — a
    /// folder's listing can wait out the dataless-folder reads' deadline, and each file is a read
    /// from disk — and the pool is as wide as the cores, shared by every task in the app. A scan
    /// of a big folder holding six of its threads would stall the rest; and when the rest held
    /// them, measured in the full FileExplorer suite, this scan did not take a step in 15 s
    /// (`docs/flaky-tests.md`, "Every gate parks at once, on the pool their releases need"). So
    /// the walk has a thread, and the reads an operation queue six wide.
    ///
    /// **Cancelled by ending the stream** — the caller drops it when the query changes, and the
    /// walk and the reads stop at their next check: no new file is opened after that.
    ///
    /// - Parameters:
    ///   - facts: the one `lstat` per path — a seam because a dataless file cannot be made in a
    ///     test: `SF_DATALESS` is set only by a File Provider.
    ///   - read: reads one file the walk chose. `BoundedTextRead`'s, whose own dataless check runs
    ///     again just before the open.
    static func search(
        _ query: String,
        in root: String,
        fileManager: FileManaging = FileManager.default,
        facts: @escaping @Sendable (String) -> FileFacts? = FileFacts.real,
        read: @escaping @Sendable (String) -> BoundedTextRead.Outcome = { BoundedTextRead.read(path: $0) },
        limits: Limits = .standard
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let flag = StopFlag()
            continuation.onTermination = { _ in flag.stop() }
            let thread = Thread {
                run(query, in: root, fileManager: fileManager, facts: facts, read: read, limits: limits,
                    flag: flag, continuation: continuation)
                continuation.finish()
            }
            thread.name = "Edit content search"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// The search itself, on its own thread: the walk, then the reads, six at a time.
    private static func run(_ query: String, in root: String, fileManager: FileManaging,
                            facts: @escaping @Sendable (String) -> FileFacts?,
                            read: @escaping @Sendable (String) -> BoundedTextRead.Outcome,
                            limits: Limits, flag: StopFlag,
                            continuation: AsyncStream<Event>.Continuation) {
        guard let needle = needle(query) else {
            continuation.yield(.finished(Summary()))
            return
        }
        let walk = walk(root: root, fileManager: fileManager, facts: facts, limits: limits,
                        isStopped: { flag.isStopped })
        guard !flag.isStopped else { return }
        let found = walk.candidates.count
        continuation.yield(.progress(Progress(found: found, walked: true)))

        // What the readers share, under one lock: how many have been read, how many matched, and
        // whether the file limit has stopped the rest.
        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var read = 0
            var matched = 0
            var full = false
            /// A file that matched, or might have, and is not listed: the limit left it out.
            var leftOut = false
        }
        let tally = Tally()
        let readers = OperationQueue()
        readers.name = "Edit content search reads"
        readers.maxConcurrentOperationCount = maxConcurrentReads
        readers.qualityOfService = .userInitiated
        for candidate in walk.candidates {
            readers.addOperation {
                tally.lock.lock()
                let skip = tally.full
                tally.lock.unlock()
                guard !skip, !flag.isStopped else {
                    if skip { tally.lock.lock(); tally.leftOut = true; tally.lock.unlock() }
                    return
                }
                let lines = read(candidate.path).string.map {
                    matchingLines(in: $0, needle: needle, keeping: limits.linesPerFile)
                }
                tally.lock.lock()
                defer { tally.lock.unlock() }
                tally.read += 1
                if let lines, lines.count > 0, tally.full { tally.leftOut = true }
                if let lines, lines.count > 0, !tally.full, !flag.isStopped {
                    tally.matched += 1
                    tally.full = tally.matched >= limits.files
                    let hit = EditorContentHit(path: candidate.path,
                                               name: (candidate.path as NSString).lastPathComponent,
                                               subfolder: candidate.subfolder, kind: .text,
                                               lines: lines.lines, lineCount: lines.count)
                    continuation.yield(.hit(hit, order: candidate.order))
                }
                // Every 25 files, and the last: often enough to move, rarely enough not to redraw
                // the rail for every file.
                if tally.read % 25 == 0 || tally.read == found {
                    continuation.yield(.progress(Progress(read: tally.read, found: found, walked: true)))
                }
            }
        }
        readers.waitUntilAllOperationsAreFinished()
        guard !flag.isStopped else { return }
        var summary = Summary()
        summary.read = tally.read
        summary.matched = tally.matched
        summary.notDownloaded = walk.notDownloaded
        summary.tooLarge = walk.tooLarge
        summary.unansweredFolders = walk.unansweredFolders
        // The file limit is a stop only when it left a file out: met by the last file that matched,
        // the search listed everything it found.
        summary.stop = walk.stop ?? (tally.leftOut ? .fileLimit(limits.files) : nil)
        continuation.yield(.finished(summary))
    }
}

/// **Where a Contents result sends the editor** (RD38): a line, a column and a length — the
/// match — and the word, for Find.
struct EditorContentMatch: Equatable {
    var path: String
    var line: Int
    var column: Int
    var length: Int
    var word: String

    /// The match as it stands in `text` — the file as it opened, which can differ from the file as
    /// the search read it: it may have been edited since.
    ///
    /// **Checked, then looked for.** Where the result says the match is, the word is selected if it
    /// is still there; if not, the first match at or after the start of that line is; if the word
    /// has gone from there on, the caret goes to the line's start, with nothing selected.
    static func located(_ match: EditorContentMatch, in text: String, using index: EditorLineIndex) -> EditorContentMatch {
        let ns = text as NSString
        let offset = EditorGoToLine.utf16Offset(of: EditorGoToLine.Target(line: match.line, column: match.column),
                                                in: text, using: index)
        if match.length > 0, offset + match.length <= ns.length,
           ns.substring(with: NSRange(location: offset, length: match.length))
               .compare(match.word, options: EditorContentSearch.matchOptions) == .orderedSame {
            return match
        }
        let lineStart = EditorGoToLine.utf16Offset(of: EditorGoToLine.Target(line: match.line, column: 1),
                                                   in: text, using: index)
        var moved = match
        let found = match.word.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : ns.range(of: match.word, options: EditorContentSearch.matchOptions,
                       range: NSRange(location: lineStart, length: ns.length - lineStart))
        guard found.location != NSNotFound else {
            moved.column = 1
            moved.length = 0
            return moved
        }
        let caret = EditorCaret.at(utf16Offset: found.location, in: text)
        moved.line = caret.line
        moved.column = caret.column
        moved.length = found.length
        return moved
    }
}
