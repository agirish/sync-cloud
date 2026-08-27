import Foundation
import Sync

/// A `-L`/`-R` value that is neither a known provider nor an existing path.
public struct ProviderResolutionError: Error, Equatable, Sendable {
    public let message: String
}

/// An absolute, symlink-free spelling of `path`, for comparing two ways of naming one folder.
///
/// `URL(fileURLWithPath:)` makes a relative argument absolute against the working directory, which
/// is what `fileExists` already resolved it against, and `resolvingSymlinksInPath` collapses the
/// `~/iCloud` → iCloud Drive convention onto the provider's own root.
func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
        // **An argument that names BOTH a provider and a real directory is refused, not guessed.**
        // The provider branch wins by position, so `-L Dropbox` run beside a local folder called
        // `Dropbox` silently addressed the provider's root instead of the folder in front of the
        // user — and `sync` is a mass copy, so guessing wrong here is not a wrong listing, it is
        // the whole of one tree written into another.
        //
        // Neither precedence is defensible: reversing it just moves the same silent misfire onto
        // whoever meant the provider. The CLI cannot know which was meant, and saying so costs one
        // command re-run, while being wrong costs a sync. Both spellings that disambiguate are
        // offered, and both work — a provider id never contains a slash, so `./Dropbox` and an
        // absolute path both miss this branch and land on the path branch below.
        // **Only when the two readings are DIFFERENT trees.** `~/iCloud` symlinked to iCloud Drive
        // is a common convention, and there the provider and the directory are the same folder —
        // refusing would be pedantry with no hazard behind it. Compared after resolving symlinks,
        // which is what makes that case identical rather than merely similar.
        let asPath = expandPath(value)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: asPath, isDirectory: &isDirectory), isDirectory.boolValue,
           canonicalPath(asPath) != canonicalPath(expandPath(provider.rootPath)) {
            throw ProviderResolutionError(
                message: "'\(value)' for \(label) names both the provider '\(provider.displayName)' "
                    + "(\(provider.rootPath)) and a directory at \(asPath). "
                    + "Use './\(value)' or an absolute path for the directory, "
                    + "or rename the directory to address the provider by name.")
        }
        try requireDirectory(
            atPath: expandPath(provider.rootPath),
            fileManager: fileManager,
            missingMessage: "Root '\(provider.rootPath)' of provider '\(provider.displayName)' (\(label)) does not exist. "
                + "The provider may be unmounted or signed out.",
            notDirectoryMessage: "Root '\(provider.rootPath)' of provider '\(provider.displayName)' (\(label)) is not a directory."
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
    // A path has no provider identity of its own, so take the type from whichever discovered
    // provider contains it (see `CloudProvider.inferredType`). Both the destination name guard
    // and the Google Drive date-noise filter are type-gated, and a fixed type silently disabled
    // them for the very roots that need them: the OneDrive folder that skips `CON.txt` when
    // addressed by id would copy it when addressed by path. Falls back to `.iCloud`, whose rule
    // set is empty — the right answer for an ordinary local folder, and what every path-addressed
    // root got before inference existed.
    let inferredType = CloudProvider.inferredType(forPath: expanded, among: providers) ?? .iCloud
    // A path-addressed root is its own root and lands on itself: the user named one folder and
    // meant that folder. `openAt` defaults to "", so `landingPath == rootPath` here and the two
    // readings of this value cannot come apart.
    return CloudProvider(
        id: expanded,
        displayName: label,
        imageName: "folder",
        rootPath: expanded,
        type: inferredType
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
