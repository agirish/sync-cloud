import AppKit
import UniformTypeIdentifiers

/// System file icons for tree rows, cached by file extension so large trees (14k+ nodes)
/// never pay a per-row NSWorkspace fetch. Keys are lowercased path extensions — files
/// directly, directories under a "/" prefix so bundle-style folders (.app, .photoslibrary)
/// show their type's icon while plain folders share one generic entry — keeping the cache
/// bounded by the number of distinct extensions on screen, not by node count. Lookups
/// resolve through `NSWorkspace.icon(for: UTType)`, which is metadata-only and never
/// touches the disk; per-path icons (custom folder icons, a specific app's own icon) are
/// deliberately not supported because they would require per-node I/O.
@MainActor
enum FileIconCache {
    /// Key prefix for directories (the bare prefix is every plain folder's key). "/" can
    /// never appear in a file's path extension, so no file key can collide with it.
    nonisolated static let directoryKey = "/"

    private static var icons: [String: NSImage] = [:]

    /// Pure key derivation: files key on their lowercased path extension ("" for
    /// extensionless files and dotfiles); directories key on "/" + that extension, so
    /// bundle-style folders get their own entry and extensionless folders share "/".
    nonisolated static func cacheKey(name: String, isDirectory: Bool) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return isDirectory ? directoryKey + ext : ext
    }

    /// The UTType whose system icon represents a cache key. Directory keys must resolve
    /// with the `.directory` conformance hint — the plain lookup returns the FILE type for
    /// an extension like "app" (com.apple.application-file, not the bundle) — and only a
    /// DECLARED result counts: an unknown extension yields a dyn.* placeholder, and a
    /// folder named "v1.2" must stay a generic folder. `UTType(filenameExtension:)` is a
    /// Launch Services metadata lookup; no disk I/O.
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
