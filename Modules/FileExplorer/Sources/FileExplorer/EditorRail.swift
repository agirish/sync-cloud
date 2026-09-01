import Foundation
import Sync

/// One row of the editor's file rail.
public struct EditorRailEntry: Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var size: Int
    public var isCloudOnly: Bool

    public init(path: String, name: String, size: Int, isCloudOnly: Bool) {
        self.path = path
        self.name = name
        self.size = size
        self.isCloudOnly = isCloudOnly
    }

    public var id: String { path }

    /// Bigger than the editor is willing to read.
    public var isTooLarge: Bool { size > BoundedTextRead.maxBytes }

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
    /// Worded to match `BoundedTextRead.Outcome.caption`, which is what the editor shows when the
    /// same file is opened anyway — two surfaces saying the same thing about one file.
    public var dimmedReason: String? {
        if isCloudOnly { return "Not downloaded — there is nothing here to read yet." }
        if isTooLarge {
            return "Too large to open (\(FileSyncManager.formatBytes(size)); the limit is "
                + "\(FileSyncManager.formatBytes(BoundedTextRead.maxBytes)))."
        }
        return nil
    }
}

/// Which of a folder's files the editor will list.
public enum EditorRail {

    /// The text-like files directly inside `folder`, in the order the rail draws them.
    ///
    /// **One level, no recursion.** The rail answers "what can I open in the folder I am standing
    /// in"; a recursive list would answer a different question and would walk a tree on every
    /// selection change in the sidebar.
    ///
    /// Directories are skipped rather than listed — the sidebar is how you change folder, and a
    /// folder row here would be a second, weaker way to do it that lands somewhere the sidebar does
    /// not agree with.
    public static func entries(in folder: String,
                        showsHidden: Bool,
                        fileManager: FileManager = .default,
                        isCloudOnly: (String) -> Bool = {
                            MaterializationStatus.isCloudOnly(atPath: $0)
                        }) -> [EditorRailEntry] {
        guard !folder.isEmpty,
              let names = try? fileManager.contentsOfDirectory(atPath: folder) else { return [] }
        var rows: [EditorRailEntry] = []
        for name in names {
            guard showsHidden || !name.hasPrefix(".") else { continue }
            guard PairContentKind.classify(path: name) == .text else { continue }
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
                                        isCloudOnly: isCloudOnly(path)))
        }
        // Localized standard order, so "note 2" sorts before "note 10" and the rail reads the way
        // Finder does rather than the way ASCII does.
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
