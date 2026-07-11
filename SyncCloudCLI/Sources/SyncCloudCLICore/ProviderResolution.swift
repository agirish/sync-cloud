import Foundation
import Sync

/// A `-L`/`-R` value that is neither a known provider nor an existing path.
public struct ProviderResolutionError: Error, Equatable, Sendable {
    public let message: String
}

/// Expands a leading tilde in a user-supplied path.
public func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// Resolves a `-L`/`-R` argument to a provider: first by id or display name among the
/// discovered providers, else as a filesystem path (tilde-expanded) wrapped in an ad-hoc
/// provider. Throws `ProviderResolutionError` when neither matches, or when the resolved
/// root is not an existing directory.
///
/// The root check is load-bearing, not cosmetic: `FileDiffEngine.getFilesInDirectory` returns
/// an empty map for a missing root (a nonexistent root still yields a non-nil enumerator), so
/// an unmounted provider (e.g. a removed `~/Library/CloudStorage` folder) would scan as
/// "everything missing on this side" and `sync` would mass-copy the entire other side into a
/// recreated dead tree the provider never syncs. The app guards this in its pane layer; the
/// CLI must guard it here, where every command resolves its roots.
public func resolveProviderOrPath(
    value: String,
    label: String,
    providers: [CloudProvider],
    fileManager: FileManaging = FileManager.default
) throws -> CloudProvider {
    if let provider = providers.first(where: { $0.id == value || $0.displayName == value }) {
        try requireDirectory(
            atPath: expandPath(provider.path),
            fileManager: fileManager,
            missingMessage: "Root '\(provider.path)' of provider '\(provider.displayName)' (\(label)) does not exist. "
                + "The provider may be unmounted or signed out.",
            notDirectoryMessage: "Root '\(provider.path)' of provider '\(provider.displayName)' (\(label)) is not a directory."
        )
        return provider
    }
    let expanded = expandPath(value)
    try requireDirectory(
        atPath: expanded,
        fileManager: fileManager,
        missingMessage: "Path or provider '\(value)' for \(label) could not be found.",
        notDirectoryMessage: "Path '\(expanded)' for \(label) is not a directory."
    )
    return CloudProvider(
        id: expanded,
        displayName: label,
        imageName: "folder",
        path: expanded,
        type: .iCloud
    )
}

/// Scan and sync both require a root that exists and is a directory; a file root would fail
/// the same "empty enumerator" way a missing one does.
private func requireDirectory(
    atPath path: String,
    fileManager: FileManaging,
    missingMessage: String,
    notDirectoryMessage: String
) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw ProviderResolutionError(message: missingMessage)
    }
    guard isDirectory.boolValue else {
        throw ProviderResolutionError(message: notDirectoryMessage)
    }
}
