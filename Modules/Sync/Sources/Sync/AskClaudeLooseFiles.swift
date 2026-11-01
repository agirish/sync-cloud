import Foundation

/// A folder's loose files for Ask Claude's filing card (TE267): which files count, and the checks
/// a row makes against the folder it would go to.
///
/// **Loose** (decision FZ): every file in the folder and in its subfolders, each on its own.
/// Skipped: hidden files and folders (a leading dot, or the Never show Claude list, counted only),
/// unfinished downloads, and what is inside a package, which is one document. Apps and installers
/// are kept apart as "left here": the card never moves them.
public enum AskClaudeLooseFiles {

    public struct File: Sendable, Equatable {
        public let path: String
        public let name: String
        public let size: Int?
        public let modified: Date?
    }

    public struct Found: Sendable, Equatable {
        /// Newest first.
        public var files: [File] = []
        public var installers: [File] = []
        public var unfinished = 0
        /// Items on the Never show Claude list, which are counted and never named.
        public var hidden = 0
        /// Files directly in the folder, and how many subfolders held the rest.
        public var topLevel = 0
        public var subfolders = 0
        /// The walk stopped at `limit` items, so there may be more than it found.
        public var truncated = false
        /// Each subfolder under the folder, absolute, and whether everything in it is a loose file
        /// (no installer, unfinished or hidden item anywhere inside it): one the card's moves could
        /// leave empty (decision GA).
        public var emptiable: [String: Bool] = [:]
        /// Each subfolder's loose files, at any depth, for the same question.
        public var filesUnder: [String: Set<String>] = [:]
    }

    /// Extensions the card leaves where they are.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "app", "iso"]
    /// A browser's download still on its way.
    static let unfinishedExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    public static func isInstaller(_ name: String) -> Bool {
        installerExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func isUnfinished(_ name: String) -> Bool {
        unfinishedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The loose files under `folder`, absolute and spelled as given (a link on the way stays a
    /// link: `contentsOfDirectory(at:)` would resolve it). Stops after `limit` items.
    public static func collect(in folder: String, isHidden: (String) -> Bool, limit: Int = 2_000,
                               fileManager fm: FileManager = .default) -> Found {
        var found = Found()
        var seen = 0
        /// Returns whether everything under `dir` is a loose file.
        @discardableResult
        func walk(_ dir: String, depth: Int) -> Bool {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return false }
            var allLoose = true
            for name in names.sorted() {
                if name == ".DS_Store" { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasPrefix(".") { allLoose = false; continue }
                if isHidden(path) { found.hidden += 1; allLoose = false; continue }
                guard seen < limit else { found.truncated = true; return false }
                seen += 1
                let url = URL(fileURLWithPath: path)
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                                              .fileSizeKey, .contentModificationDateKey])
                // A link to a folder isn't walked into: what it reaches lives somewhere else.
                if values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true {
                    if depth == 0 { found.subfolders += 1 }
                    let before = found.files.count
                    let loose = walk(path, depth: depth + 1)
                    found.emptiable[path] = loose
                    found.filesUnder[path] = Set(found.files[before...].map(\.path))
                    if !loose { allLoose = false }
                    continue
                }
                if isUnfinished(name) { found.unfinished += 1; allLoose = false; continue }
                let file = File(path: path, name: name, size: values?.fileSize, modified: values?.contentModificationDate)
                if isInstaller(name) { found.installers.append(file); allLoose = false; continue }
                if values?.isSymbolicLink == true { allLoose = false; continue }
                found.files.append(file)
                if depth == 0 { found.topLevel += 1 }
            }
            return allLoose
        }
        walk(folder, depth: 0)
        // `filesUnder` is filled in walk order, so it is set before the files are sorted.
        found.files.sort { ($0.modified ?? .distantPast, $1.name) > ($1.modified ?? .distantPast, $0.name) }
        return found
    }

    /// The outermost subfolders that the card's own files would leave empty: everything in them,
    /// at any depth, is one of `onCard`.
    public static func emptiedFolders(_ found: Found, onCard: Set<String>) -> [String] {
        let emptied = found.emptiable.keys.filter { folder in
            found.emptiable[folder] == true && !(found.filesUnder[folder] ?? []).isEmpty
                && (found.filesUnder[folder] ?? []).isSubset(of: onCard)
        }
        // A folder inside another that goes too is taken with it.
        return emptied.filter { folder in !emptied.contains { folder.hasPrefix($0 + "/") } }.sorted()
    }

    /// A file in `folder` holding exactly the bytes of `path` (decision GF), or nil. Only files of
    /// the same size are read, and never one only in the cloud: reading it would download it.
    public static func sameFile(as path: String, in folder: String, size: Int?,
                                isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnlyIfKnown(atPath: $0) == true },
                                fileManager fm: FileManager = .default) -> String? {
        guard let size, size > 0, !isCloudOnly(path), let names = try? fm.contentsOfDirectory(atPath: folder) else { return nil }
        for name in names.sorted() where !name.hasPrefix(".") {
            let other = (folder as NSString).appendingPathComponent(name)
            guard other != path,
                  let values = try? URL(fileURLWithPath: other).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, values.fileSize == size, !isCloudOnly(other) else { continue }
            if sameBytes(path, other) { return other }
        }
        return nil
    }

    /// The two files hold the same bytes, read a megabyte at a time.
    public static func sameBytes(_ a: String, _ b: String) -> Bool {
        guard let ha = FileHandle(forReadingAtPath: a), let hb = FileHandle(forReadingAtPath: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        while true {
            let da = (try? ha.read(upToCount: 1 << 20)) ?? nil
            let db = (try? hb.read(upToCount: 1 << 20)) ?? nil
            if da != db { return false }
            if da == nil || da?.isEmpty == true { return true }
        }
    }

    /// The name `name` would land under in `folder`: itself, or "Ticket 2.pdf" when it is taken
    /// (decision GE), as filing's own move names it.
    public static func landingName(for name: String, in folder: String, fileManager fm: FileManager = .default) -> String {
        let target = URL(fileURLWithPath: folder).appendingPathComponent(name)
        guard fm.fileExists(atPath: target.path) else { return name }
        return FileSyncManager.generateUniqueURL(for: target, fileManager: fm).lastPathComponent
    }
}

extension AskClaudeLooseFiles {

    /// What Claude is told about a filing card: each row's name, folder, confidence and whether
    /// it is ticked. Never a reason, which can name a word read from the file, and never a path
    /// outside the labels the card shows.
    public static func result(_ plan: AskClaudePlan, leftHereCount: Int, nextFrom: Int?) -> String {
        var lines = ["They have a card: \(AskClaudeScreenCard.escape(plan.title)), \(AskClaudeScreenCard.escape(plan.subtitle)). Nothing was moved.",
                     "rows: name|folder|confidence|ticked|note"]
        for (group, rows) in plan.groups {
            for row in rows {
                let folder: String
                switch group {
                case .folder(let label): folder = label
                case .needsPick: folder = "needs their pick: " + row.choices.map(\.label).joined(separator: " or ")
                case .alreadyFiled: folder = "already filed; a Trash row"
                case .emptied: folder = "emptied folders; a Trash row"
                }
                lines.append([row.name, folder, row.confidence ?? "", row.ticked ? "ticked" : "not ticked", row.note ?? ""]
                    .map(AskClaudeScreenCard.escape).joined(separator: "|"))
            }
        }
        if let left = plan.leftHere, leftHereCount > 0 { lines.append(AskClaudeScreenCard.escape(left)) }
        if let nextFrom, let more = plan.more {
            lines.append("\(AskClaudeScreenCard.escape(more)). For the next ones, call again with from \(nextFrom).")
        }
        lines.append("Say in a line or two how many have a sure home and what needs their pick. Don’t list the files: the card shows them.")
        return lines.joined(separator: "\n")
    }
}
