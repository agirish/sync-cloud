import Foundation

/// What Ask Claude may see and read: the “Never show Claude” list and the folders shared without
/// asking. Each folder is one of three: asked about, shared without asking, or hidden.
public enum AskClaudePrivacy {

    public static let hiddenFoldersKey = "askClaudeHiddenFolders"
    /// The retired “Let Claude read files” switch; read once, by `retireReadsFiles`.
    public static let retiredReadsFilesKey = "askClaudeReadsFiles"
    /// The folders Claude gets answers, passages and search names from without a card ("Share
    /// Without Asking"). Hidden wins over it; whole documents always ask.
    public static let sharedFoldersKey = "askClaudeSharedFolders"
    public static let didChange = Notification.Name("AskClaudePrivacyDidChange")

    /// Absolute paths of the folders Claude must never be shown, in the order they were added.
    public static func hiddenFolders(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: hiddenFoldersKey) ?? []
    }

    public static func setHiddenFolders(_ folders: [String], in defaults: UserDefaults) {
        defaults.set(folders, forKey: hiddenFoldersKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func hide(_ folder: String, in defaults: UserDefaults) {
        let path = (folder as NSString).standardizingPath
        // One folder is asked about, shared without asking or hidden, never two at once.
        stopSharing(path, in: defaults)
        var folders = hiddenFolders(in: defaults)
        guard !folders.contains(path) else { return }
        folders.append(path)
        setHiddenFolders(folders, in: defaults)
    }

    /// Absolute paths of the folders shared without asking, in the order they were added.
    public static func sharedFolders(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: sharedFoldersKey) ?? []
    }

    public static func setSharedFolders(_ folders: [String], in defaults: UserDefaults) {
        defaults.set(folders, forKey: sharedFoldersKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Share Without Asking for `folder` and everything in it; it comes off the hidden list.
    public static func shareWithoutAsking(_ folder: String, in defaults: UserDefaults) {
        let path = (folder as NSString).standardizingPath
        if hiddenFolders(in: defaults).contains(path) { unhide(path, in: defaults) }
        var folders = sharedFolders(in: defaults)
        guard !folders.contains(path) else { return }
        folders.append(path)
        setSharedFolders(folders, in: defaults)
    }

    /// The hidden entries that hide `path`: its own, and any folder above it. Sharing it takes
    /// these off, as the shield does, because hidden wins over shared.
    public static func hiddenEntries(covering path: String, in defaults: UserDefaults) -> [String] {
        hiddenFolders(in: defaults).filter { isHidden(path, by: [$0]) }
    }

    public static func stopSharing(_ folder: String, in defaults: UserDefaults) {
        let folders = sharedFolders(in: defaults)
        guard folders.contains(folder) else { return }
        setSharedFolders(folders.filter { $0 != folder }, in: defaults)
    }

    public static func unhide(_ folder: String, in defaults: UserDefaults) {
        setHiddenFolders(hiddenFolders(in: defaults).filter { $0 != folder }, in: defaults)
    }

    /// Whether `path` is a hidden folder or anything inside one.
    public static func isHidden(_ path: String, by folders: [String]) -> Bool {
        guard !folders.isEmpty else { return false }
        return Matcher(folders).isHidden(path)
    }

    /// The hidden-folder check for many paths, such as every row of a folder.
    ///
    /// - Both spellings of a linked folder count (iCloud's Documents is a link to ~/Documents).
    /// - Case is ignored, as the Mac's disk ignores it: `documents/private` is the same folder as
    ///   `Documents/Private`, so it must be hidden the same. On a case-sensitive volume this hides
    ///   a little more than asked, never less.
    /// - Links are resolved once per folder, not per row: rows share their parent, and resolving a
    ///   path costs a file-system call per component. A row that is itself a link is resolved on
    ///   its own.
    public final class Matcher {
        private let prefixes: [String]
        private var realParents: [String: String] = [:]

        /// The folders where they really are, for `holds`.
        private let realPrefixes: [String]

        public init(_ folders: [String]) {
            let spellings = folders.flatMap { [($0 as NSString).standardizingPath, ($0 as NSString).resolvingSymlinksInPath] }
            prefixes = Array(Set(spellings.map { $0.lowercased() }))
            realPrefixes = Array(Set(folders.map { ($0 as NSString).resolvingSymlinksInPath.lowercased() }))
        }

        public var isEmpty: Bool { prefixes.isEmpty }

        public func isHidden(_ path: String) -> Bool {
            guard !prefixes.isEmpty else { return false }
            let standard = (path as NSString).standardizingPath
            if matches(standard) { return true }
            return matches(real(standard))
        }

        /// Whether `path` really is in one of the folders, by where it is on disk alone: for a
        /// list that loosens what Claude gets, such as the folders shared without asking. Counting
        /// by spelling too, as `isHidden` does, is right only for a list that keeps things back:
        /// here a link inside a shared folder would share its target.
        public func holds(_ path: String) -> Bool {
            guard !prefixes.isEmpty else { return false }
            let target = real((path as NSString).standardizingPath)
            return realPrefixes.contains { target.lowercased() == $0 || target.lowercased().hasPrefix($0 + "/") }
        }

        private func real(_ standard: String) -> String {
            let parent = (standard as NSString).deletingLastPathComponent
            let realParent: String
            if let known = realParents[parent] {
                realParent = known
            } else {
                realParent = (parent as NSString).resolvingSymlinksInPath
                realParents[parent] = realParent
            }
            var info = stat()
            let isLink = lstat(standard, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
            return isLink ? (standard as NSString).resolvingSymlinksInPath
                : (realParent as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
        }

        private func matches(_ path: String) -> Bool {
            let lower = path.lowercased()
            return prefixes.contains { lower == $0 || lower.hasPrefix($0 + "/") }
        }
    }

    /// Carries the retired “Let Claude read files” switch over: on, it shared every folder not
    /// hidden, so `home` is shared without asking in its place; off, nothing changes. The key goes
    /// either way, so this runs once. Hidden folders stay hidden: hidden wins over shared.
    /// - Returns: a log line when it moved anything.
    @discardableResult
    public static func retireReadsFiles(home: String, in defaults: UserDefaults) -> String? {
        guard defaults.object(forKey: retiredReadsFilesKey) != nil else { return nil }
        let wasOn = defaults.bool(forKey: retiredReadsFilesKey)
        defaults.removeObject(forKey: retiredReadsFilesKey)
        guard wasOn else { return nil }
        let path = (home as NSString).standardizingPath
        var folders = sharedFolders(in: defaults)
        if !folders.contains(path) {
            folders.append(path)
            setSharedFolders(folders, in: defaults)
        }
        return "Let Claude read files was on, so the home folder is now shared without asking"
    }
}

/// Names a content search found, held for their click: which files mention a word says what is
/// inside them ("diagnosis"), so outside a folder shared without asking the list waits on a card,
/// as a file's answer does, and goes only by its share (Share Details or Customize's).
public struct AskClaudeFoundNames: Codable, Equatable, Sendable {
    /// The words searched for, as Claude gave them.
    public let words: String
    /// Where: “iCloud › Documents”.
    public let folderLabel: String
    /// The files' names, newest period first, as the card shows them.
    public let names: [String]
    /// How many matched, which can be more than `names` lists.
    public let count: Int
    /// What Share Details sends: the rows Claude would otherwise have had (handles minted at the share).
    public let rows: String
    /// The files, so Share refuses one hidden from Claude since.
    public let paths: [String]
    /// Whether they shared them; nil until they do.
    public var sent: Bool?
    /// Each file, to tick and to show what goes: its folder and date on the card, and its row for
    /// Share N Files. Nil on an older saved card without ticks.
    public let files: [File]?
    /// The lines above the rows: how many matched, and the rows' columns.
    public let header: String?
    /// The files they unticked, by path: neither share sends them.
    public var unticked: [String]?
    /// Whether what went was the names alone (Customize with every detail unticked).
    public var namesOnly: Bool?
    /// What found them: a search inside files (nil, as on older saved cards), or a lookup beyond
    /// the folder on screen (a name search or a folder's listing).
    public let source: Source?
    /// Whether Spotlight answered a name search; false when the pane's opened folders did.
    public let fromIndex: Bool?
    /// Whether every one is a file; a lookup can find folders too, which the card calls items.
    public let allFiles: Bool?
    /// The folder searched or listed, so a share or a Retry refuses once it is hidden from Claude
    /// even when nothing was found in it. Nil on an older saved card.
    public let folderPath: String?
    /// Customize is open: the table gives way to ticks for files and details.
    public var customizing: Bool?
    /// The details they left out under Customize, by key (`detailKeys`); names always go.
    public var omitted: [String]?

    /// The details a file can go with, in the order the card shows and the rows send them.
    public static let detailKeys = ["folder", "kind", "size", "date", "tags"]

    /// Whether the card is in Customize: opened, or saved by an older build with on-card ticks,
    /// which Customize shows and keeps.
    public var customized: Bool { customizing == true || unticked != nil }

    /// The details Customize sends: every one but those left out.
    public var chosenDetails: [String] { Self.detailKeys.filter { !(omitted ?? []).contains($0) } }

    public struct File: Codable, Equatable, Sendable {
        public let name: String
        /// Relative to the source: “Medical/2026”, or “(top level)”.
        public let folder: String
        public let modified: Date?
        /// The row Share N Files sends: handle, name, kind, size, date, tags, folder.
        public let row: String
        public let path: String

        public init(name: String, folder: String, modified: Date?, row: String, path: String) {
            self.name = name
            self.folder = folder
            self.modified = modified
            self.row = row
            self.path = path
        }

        /// The row with only the details chosen: its name, then each detail in `detailKeys`
        /// order, and no handle. The row's parts are handle|name|kind|size|modified|tags|folder
        /// (the handle empty until shared), and a part never holds a pipe (`AskClaudeScreenCard.escape`).
        public func row(with details: [String]) -> String {
            let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let at = ["kind": 2, "size": 3, "date": 4, "tags": 5, "folder": 6]
            let picked = AskClaudeFoundNames.detailKeys.filter(details.contains).map { key in
                at[key].flatMap { $0 < parts.count ? parts[$0] : nil } ?? ""
            }
            return ([parts.count > 1 ? parts[1] : ""] + picked).joined(separator: "|")
        }
    }

    public enum Source: String, Codable, Sendable {
        case names, listing
    }

    public init(words: String, folderLabel: String, names: [String], count: Int, rows: String, paths: [String],
                files: [File]? = nil, header: String? = nil, source: Source? = nil, fromIndex: Bool? = nil, allFiles: Bool? = nil,
                folderPath: String? = nil) {
        self.words = words
        self.folderLabel = folderLabel
        self.names = names
        self.count = count
        self.rows = rows
        self.paths = paths
        self.files = files
        self.header = header
        self.source = source
        self.fromIndex = fromIndex
        self.allFiles = allFiles
        self.folderPath = folderPath
    }

    /// "file" or "item": a lookup that found a folder calls them items, as a listing does.
    public var noun: String { source == .listing || allFiles == false ? "item" : "file" }

    /// What they are, after their count, for the share and the thread: “whose text mentions
    /// “x””, “matching “x” under Travel”, “in Medical”.
    public var subject: String {
        switch source {
        case nil: "whose text mentions “\(words)”"
        case .names: "matching “\(words)” under \(folderLabel)"
        case .listing: "in \(folderLabel)"
        }
    }

    /// The same, short, for the thread's line once shared: “mentioning “x””, “named “x””.
    public var brief: String {
        switch source {
        case nil: "mentioning “\(words)”"
        case .names: "named “\(words)”"
        case .listing: "in \(folderLabel)"
        }
    }

    /// The files still ticked: every one listed, less those unticked.
    public var ticked: [File] {
        let out = Set(unticked ?? [])
        return (files ?? []).filter { !out.contains($0.path) }
    }
}

/// Every file one question read, on one card, so the tick and footnote aren't repeated per file.
/// Each file keeps its answer, passage and whole text; a tick per file, as the search card has,
/// says which go.
public struct AskClaudeReadGroup: Codable, Equatable, Sendable {
    public var files: [AskClaudePassage]
    /// The files they unticked, by index in `files`: no share sends them.
    public var unticked: [Int]?
    public var answersSent: Bool?
    public var textSent: Bool?
    public var wholeSent: Bool?

    public init(files: [AskClaudePassage]) {
        self.files = files
        // Answers that went as they chose for the chat went for every file.
        if files.first?.autoShared != nil { answersSent = true }
        if files.first?.autoShared == .answerAndText { textSent = true }
    }

    /// What went without a card, the same for every file in the group.
    public var autoShared: AskClaudePassage.AutoShared? { files.first?.autoShared }

    /// The files still ticked.
    public var ticked: [AskClaudePassage] {
        let out = Set(unticked ?? [])
        return files.indices.filter { !out.contains($0) }.map { files[$0] }
    }

    /// Whether every ticked file's text for Share All Content is all of it: its whole text read
    /// to the end, or a passage that is the whole text.
    public var allIsAll: Bool {
        ticked.allSatisfy { $0.wholeIsAll == true || ($0.whole == nil && $0.whereInFile == "the text") }
    }

    /// A file's text for Share All Content: its whole text, or its passage when that is all of it.
    public static func allText(_ file: AskClaudePassage) -> String { file.whole ?? file.text }

    /// Whether all of the ticked files' text fits one share (`AskClaudeReading.wholeTokens`'s cap,
    /// passed in: Sync doesn't own it).
    public func wholeFits(under tokens: Int) -> Bool {
        ticked.reduce(0) { $0 + AskClaudePassage.estimatedTokens(Self.allText($1)) } <= tokens
    }
}

/// A passage of a file that could go to Claude, offered to the person as a button:
/// the on-device model read the file first, and sending the text itself is a second, explicit step.
public struct AskClaudePassage: Codable, Equatable, Sendable {
    public let fileName: String
    /// “page 3”, “pages 2–4”, or “the start”.
    public let whereInFile: String
    public let text: String
    /// The file, so a share can refuse it once its folder is hidden; nil in an older saved
    /// passage.
    public let path: String?
    /// What the on-device model answered from the file, held for their click: outside a folder
    /// shared without asking, an answer can carry the very fact a file holds (an account number, a
    /// diagnosis), so it waits on the card like the passage. Nil on a card that offers the passage
    /// alone, or an older saved one.
    public let answer: String?
    /// What Claude asked of the file, said on the card above the answer.
    public let asked: String?
    /// Whether they sent the answer; nil until they do.
    public var answerSent: Bool?
    /// All the text read from the file, for Share All Content, held to
    /// `AskClaudeReading.wholeTokens`; nil when it adds nothing to `text`.
    public let whole: String?
    /// What `whole` covers: “all 12 pages”, “pages 1–40”, “all of it”, “the first part”.
    public let wholeWhere: String?
    /// Whether `whole` is the whole document's text, not only its first pages.
    public let wholeIsAll: Bool?
    /// Whether they sent `whole`; nil until they do.
    public var wholeSent: Bool?
    /// What went without a card, and why: nil when everything waited for a click.
    public let autoShared: AutoShared?

    public enum AutoShared: String, Codable, Sendable {
        /// The answer and the passage went: the file is in a folder shared without asking.
        case answerAndText
        /// The answer went, as they chose for the rest of this chat; the text still waits.
        case answerForThisChat
    }

    public init(fileName: String, whereInFile: String, text: String, path: String? = nil,
                answer: String? = nil, asked: String? = nil,
                whole: String? = nil, wholeWhere: String? = nil, wholeIsAll: Bool? = nil, autoShared: AutoShared? = nil) {
        self.fileName = fileName
        self.whereInFile = whereInFile
        self.text = text
        self.path = path
        self.answer = answer
        self.asked = asked
        self.whole = whole
        self.wholeWhere = wholeWhere
        self.wholeIsAll = wholeIsAll
        self.autoShared = autoShared
        if autoShared != nil { answerSent = true }
    }

    /// About how many tokens the passage is: ``estimatedTokens(_:)``.
    public var tokens: Int { Self.estimatedTokens(text) }

    /// About how many tokens `text` is, by script: four characters to a token in Latin script; one
    /// per character in Chinese, Japanese and Korean (Apple's on-device model counts about 0.8 a
    /// character; Claude's is unmeasured); and two to a token in any other script, a guess made
    /// high.
    public static func estimatedTokens(_ text: String) -> Int {
        var quarters = 0
        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            if isCJK(scalar) { quarters += 4 } else if scalar.isASCII || isLatin(scalar) { quarters += 1 } else { quarters += 2 }
        }
        return max(1, quarters / 4)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x30FF, 0x3130...0x318F, 0x31F0...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// Latin letters past ASCII, their accents, and the punctuation Latin text uses.
    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00A0...0x024F, 0x0300...0x036F, 0x1E00...0x1EFF, 0x2000...0x206F, 0x20A0...0x20CF: return true
        default: return false
        }
    }
}

/// A file only in the cloud that Claude wanted to read or open, offered to the person as a card.
/// Up to `AskClaudeBrowseTools.autoDownloadBytes` the read or open downloads it on its own; over
/// that, or of unknown size, nothing downloads until they click.
public struct AskClaudeDownload: Codable, Equatable, Sendable {
    /// What happens once the file is here.
    public enum Purpose: Codable, Equatable, Sendable {
        /// The question asked again, so Claude reads it.
        case read
        /// Opened as the open asked: `in` is nil, "edit" or "preview".
        case open(in: String?)
    }

    public let fileName: String
    public let path: String
    /// The chat's handle for it, so the question asked again can name it.
    public let handle: String
    /// Nil when the provider didn't say.
    public let size: Int?
    /// Where it lives: "iCloud", "Dropbox".
    public let sourceName: String
    public let purpose: Purpose
    /// The question that wanted the file, set by the chat when the card arrives, so a read asked
    /// again once it lands carries it: the chat it was asked in can be gone by then.
    public var question: String?

    public init(fileName: String, path: String, handle: String, size: Int?, sourceName: String, purpose: Purpose,
                question: String? = nil) {
        self.fileName = fileName
        self.path = path
        self.handle = handle
        self.size = size
        self.sourceName = sourceName
        self.purpose = purpose
        self.question = question
    }

    /// "Lease.pdf is only in iCloud (38 MB)."
    public var summary: String {
        "\(fileName) is only in \(sourceName)" + (size.map { " (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))" } ?? "") + "."
    }
}
