import AppKit
import UniformTypeIdentifiers

/// System file icons for tree rows, cached by lowercased extension so a large tree never pays a
/// per-row NSWorkspace fetch and the cache stays bounded by distinct extensions, not node count.
/// Folders key under a "/" prefix, so bundle folders (.app, .photoslibrary) get their type's icon
/// and plain folders share one. Lookups go through `NSWorkspace.icon(for: UTType)`, which never
/// touches the disk; per-path icons (custom folder icons) are left out because they need per-node
/// I/O.
@MainActor
enum FileIconCache {
    /// Key prefix for directories (the bare prefix is every plain folder's key). "/" can
    /// never appear in a file's path extension, so no file key can collide with it.
    nonisolated static let directoryKey = "/"

    private static var icons: [String: NSImage] = [:]

    /// Files key on their lowercased extension ("" for extensionless files and dotfiles); folders
    /// on "/" + that extension, so extensionless folders share "/".
    nonisolated static func cacheKey(name: String, isDirectory: Bool) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return isDirectory ? directoryKey + ext : ext
    }

    /// The UTType whose system icon represents a cache key. Folder keys need the `.directory`
    /// hint, since the plain lookup gives "app" the file type, not the bundle, and only a declared
    /// result counts: an unknown extension yields a dyn.* placeholder, and a folder named "v1.2"
    /// must stay a generic folder. A Launch Services lookup; no disk I/O.
    nonisolated static func iconType(forKey key: String) -> UTType {
        if key.hasPrefix(directoryKey) {
            let ext = String(key.dropFirst(directoryKey.count))
            if !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory), type.isDeclared {
                return type
            }
            return .folder
        }
        return UTType(filenameExtension: key) ?? .data
    }

    static func icon(name: String, isDirectory: Bool) -> NSImage {
        let key = cacheKey(name: name, isDirectory: isDirectory)
        if let cached = icons[key] { return cached }
        let icon = NSWorkspace.shared.icon(for: iconType(forKey: key))
        icons[key] = icon
        return icon
    }
}
