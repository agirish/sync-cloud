import AppKit
import UniformTypeIdentifiers

/// System file icons for tree rows, cached by file extension so large trees (14k+ nodes)
/// never pay a per-row NSWorkspace fetch. Keys are lowercased path extensions plus one
/// shared entry for directories, so the cache is bounded by the number of distinct
/// extensions on screen — not by node count. Lookups resolve through
/// `NSWorkspace.icon(for: UTType)`, which is metadata-only and never touches the disk;
/// per-path icons (custom folder icons, .app bundles) are deliberately not supported
/// because they would require per-node I/O.
@MainActor
enum FileIconCache {
    /// Cache key shared by all directories. "/" can never appear in a file's path
    /// extension, so it cannot collide with a file key.
    nonisolated static let directoryKey = "/"

    private static var icons: [String: NSImage] = [:]

    /// Pure key derivation: one shared key for directories; files key on their
    /// lowercased path extension ("" for extensionless files and dotfiles).
    nonisolated static func cacheKey(name: String, isDirectory: Bool) -> String {
        isDirectory ? directoryKey : (name as NSString).pathExtension.lowercased()
    }

    static func icon(name: String, isDirectory: Bool) -> NSImage {
        let key = cacheKey(name: name, isDirectory: isDirectory)
        if let cached = icons[key] { return cached }
        let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        icons[key] = icon
        return icon
    }
}
