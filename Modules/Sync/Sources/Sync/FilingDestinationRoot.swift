import Foundation

/// Where To File suggests homes: the tree a scan files **into**, apart from the folder it reads
/// loose files **from**. Scoped to Home ▸ Downloads, filing into the source's own anchor would
/// walk all of Home and suggest homes anywhere under `~`.
///
/// The rule: a cloud source files into its own anchor. A folder source files into the folder
/// survey's root (Documents, in iCloud) because that is where the user's conventions are. A
/// choice in the File Into menu overrides either, per source, for as long as that folder exists.
public enum FilingDestinationRoot {

    /// UserDefaults key: a JSON object of source id → chosen destination folder (absolute).
    public static let storedKey = "toFileDestinationBySource"

    /// Where a source files into when nothing has been chosen. A folder source with no usable
    /// survey root keeps its own anchor, the only tree there is to suggest from.
    public static func defaultRoot(sourceIsLocalFolder: Bool, sourceAnchor: String,
                                   surveyRoot: String?, isDirectory: (String) -> Bool) -> String {
        guard sourceIsLocalFolder, let surveyRoot, !surveyRoot.isEmpty, isDirectory(surveyRoot) else {
            return sourceAnchor
        }
        return surveyRoot
    }

    /// Where `sourceId` files into now: the stored choice while its folder is there, else the
    /// default. A stored folder that has gone — renamed, deleted, an unplugged drive — falls back
    /// rather than handing the scan a root it would walk as empty.
    public static func resolve(sourceId: String, sourceIsLocalFolder: Bool, sourceAnchor: String,
                               surveyRoot: String?, stored: [String: String],
                               isDirectory: (String) -> Bool) -> String {
        if let chosen = stored[sourceId], !chosen.isEmpty, isDirectory(chosen) { return chosen }
        return defaultRoot(sourceIsLocalFolder: sourceIsLocalFolder, sourceAnchor: sourceAnchor,
                           surveyRoot: surveyRoot, isDirectory: isDirectory)
    }

    /// The stored choices, from the JSON string ``storedKey`` holds. Anything unreadable is no
    /// choice at all, which is every source on its default.
    public static func decode(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// `stored` with `sourceId` set to `path` — or cleared, when `path` is the default, so the
    /// source follows its default again if that ever moves.
    public static func encode(_ stored: [String: String], setting sourceId: String,
                              to path: String, default defaultPath: String) -> String {
        var map = stored
        if PathBoundary.relativize(path, under: defaultPath) == "" {
            map.removeValue(forKey: sourceId)
        } else {
            map[sourceId] = path
        }
        guard let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    /// The menu's name for a destination: the folder, then the source it is in —
    /// "Documents (iCloud)" — or the source's name alone when it is that source's root. The
    /// source whose root holds `path` most closely wins, so Documents in iCloud is not named after
    /// a Home folder source that also contains it.
    public static func label(for path: String, sources: [(name: String, root: String)]) -> String {
        let folder = (path as NSString).lastPathComponent
        var best: (name: String, depth: Int, isRoot: Bool)?
        for source in sources where !source.root.isEmpty {
            guard let relative = PathBoundary.relativize(path, under: source.root) else { continue }
            let depth = (source.root as NSString).pathComponents.count
            if best == nil || depth > best!.depth { best = (source.name, depth, relative.isEmpty) }
        }
        guard let best else { return folder }
        return best.isRoot ? best.name : "\(folder) (\(best.name))"
    }
}
