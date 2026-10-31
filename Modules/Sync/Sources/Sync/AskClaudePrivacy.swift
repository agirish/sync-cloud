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

    public init(fileName: String, whereInFile: String, text: String) {
        self.fileName = fileName
        self.whereInFile = whereInFile
        self.text = text
    }

    /// About four characters to a token.
    public var tokens: Int { max(1, text.count / 4) }
}
