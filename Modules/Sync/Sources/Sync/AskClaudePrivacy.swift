import Foundation

/// What Ask Claude may see and read (RD69): the “Never show Claude” list (decision DT, TE246) and
/// the “Let Claude read files” switch (decision DQ).
public enum AskClaudePrivacy {

    public static let hiddenFoldersKey = "askClaudeHiddenFolders"
    public static let readsFilesKey = "askClaudeReadsFiles"
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
        var folders = hiddenFolders(in: defaults)
        guard !folders.contains(path) else { return }
        folders.append(path)
        setHiddenFolders(folders, in: defaults)
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
    /// - **Both spellings of a linked folder** count (iCloud's Documents is a link to ~/Documents).
    /// - **Case is ignored**, as the Mac's disk ignores it: `documents/private` reads the same
    ///   folder as `Documents/Private`, so it must be hidden the same. On a case-sensitive volume
    ///   this hides a little more than asked, never less.
    /// - **Links are resolved once per folder**, not once per row: rows share their parent, and
    ///   resolving a path costs a file-system call per component. A row that is itself a link is
    ///   resolved on its own.
    public final class Matcher {
        private let prefixes: [String]
        private var realParents: [String: String] = [:]

        public init(_ folders: [String]) {
            let spellings = folders.flatMap { [($0 as NSString).standardizingPath, ($0 as NSString).resolvingSymlinksInPath] }
            prefixes = Array(Set(spellings.map { $0.lowercased() }))
        }

        public var isEmpty: Bool { prefixes.isEmpty }

        public func isHidden(_ path: String) -> Bool {
            guard !prefixes.isEmpty else { return false }
            let standard = (path as NSString).standardizingPath
            if matches(standard) { return true }
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
            let real = isLink ? (standard as NSString).resolvingSymlinksInPath
                : (realParent as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
            return matches(real)
        }

        private func matches(_ path: String) -> Bool {
            let lower = path.lowercased()
            return prefixes.contains { lower == $0 || lower.hasPrefix($0 + "/") }
        }
    }

    /// Whether Claude may be sent a passage of a file without asking each time. Off by default.
    public static func readsFiles(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: readsFilesKey)
    }
}

/// A passage of a file that could go to Claude, offered to the person as a button (decision DS):
/// the on-device model read the file first, and sending the text itself is a second, explicit step.
public struct AskClaudePassage: Codable, Equatable, Sendable {
    public let fileName: String
    /// “page 3”, “pages 2–4”, or “the start”.
    public let whereInFile: String
    public let text: String
    /// The file, so Send to Claude can refuse it once its folder is hidden; nil in a passage
    /// saved before it was kept.
    public let path: String?

    public init(fileName: String, whereInFile: String, text: String, path: String? = nil) {
        self.fileName = fileName
        self.whereInFile = whereInFile
        self.text = text
        self.path = path
    }

    /// About how many tokens the passage is: ``estimatedTokens(_:)``.
    public var tokens: Int { Self.estimatedTokens(text) }

    /// **About how many tokens `text` is, by script.** About four characters to a token in Latin
    /// script; near one a character in Chinese, Japanese and Korean — 16,000 characters of Chinese
    /// or Japanese were 12,522 tokens to Apple's on-device model (2026-11-02); Claude's count was
    /// not measured, so each counts as one — and two characters to a token in any other script, a
    /// guess, made high.
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

/// A file only in the cloud that Claude wanted to read or open, offered to the person as a card
/// (TE258). Up to `AskClaudeBrowseTools.autoDownloadBytes` the read or open downloads it on its own
/// (decision EJ); over that, or of unknown size, nothing downloads until they click.
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
