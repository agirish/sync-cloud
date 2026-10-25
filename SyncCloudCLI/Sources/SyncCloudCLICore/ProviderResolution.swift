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

/// The discovered provider a `-L`/`-R` value names, or nil when it names none.
///
/// **An exact id wins, and a display name counts only when exactly one provider carries it
/// (FR42).** This used to be the first provider whose id OR display name matched, in discovery
/// order — and neither half of that is unique. Two folder sources whose folders share a last
/// path component get the same default display name, and a provider renamed to another
/// provider's id made one value name two trees. `-L Dropbox` then quietly meant whichever came
/// first, and under `sync --yes` that is the tree it wrote into.
///
/// An id is the stable handle (`synccloud providers` lists it), so a value that is some
/// provider's id means that provider even when another's display name happens to read the
/// same. A display name shared by several providers is refused rather than guessed, naming every
/// candidate's id and the folder it would scan — its `landingPath`, which is what `CommandRunner`
/// scans, not the account root above it — so the re-run can say which. Ids are expected to be unique; two
/// providers claiming one are refused the same way rather than trusted to discovery order.
func matchingProvider(
    for value: String,
    label: String,
    among providers: [CloudProvider]
) throws -> CloudProvider? {
    func refusal(_ candidates: [CloudProvider], by what: String, remedy: String) -> ProviderResolutionError {
        let listed = candidates.map { "'\(CLIOutput.verbatim($0.id))' (\(CLIOutput.verbatim($0.landingPath)))" }.joined(separator: ", ")
        return ProviderResolutionError(
            message: "'\(CLIOutput.verbatim(value))' for \(label) matches \(candidates.count) providers by \(what): \(listed). \(remedy)")
    }
    let byID = providers.filter { $0.id == value }
    if byID.count > 1 {
        throw refusal(byID, by: "id", remedy: "Pass the folder's path instead.")
    }
    if let provider = byID.first { return provider }
    let byName = providers.filter { $0.displayName == value }
    if byName.count > 1 {
        throw refusal(byName, by: "name",
                      remedy: "Pass one of those ids (see `synccloud providers`) or the folder's path to say which.")
    }
    return byName.first
}

/// Resolves a `-L`/`-R` argument to a provider: first among the discovered providers (see
/// `matchingProvider` — an exact id, else a display name only one provider carries), else as a
/// filesystem path (tilde-expanded) wrapped in an ad-hoc provider. Throws
/// `ProviderResolutionError` when neither matches, when a display name is ambiguous, or when the
/// resolved root is not an existing directory.
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
    if let provider = try matchingProvider(for: value, label: label, among: providers) {
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
                message: "'\(CLIOutput.verbatim(value))' for \(label) names both the provider '\(provider.displayName)' "
                    + "(\(CLIOutput.verbatim(provider.rootPath))) and a directory at \(CLIOutput.verbatim(asPath)). "
                    + "Use '\(CLIOutput.verbatim("./" + value))' or an absolute path for the directory, "
                    + "or rename the directory to address the provider by name.")
        }
        try requireDirectory(
            atPath: expandPath(provider.rootPath),
            fileManager: fileManager,
            missingMessage: "Root '\(CLIOutput.verbatim(provider.rootPath))' of provider '\(provider.displayName)' (\(label)) does not exist. "
                + "The provider may be unmounted or signed out.",
            notDirectoryMessage: "Root '\(CLIOutput.verbatim(provider.rootPath))' of provider '\(provider.displayName)' (\(label)) is not a directory."
        )
        // **Then the folder the run will actually scan**, which is not the one above. A source's
        // root is the account, and `CommandRunner` scans `landingPath` — so this pre-flight cleared
        // a directory the run never touches, and a mounted account whose landing folder had been
        // renamed got past it and failed later, deeper, with a message about the root instead.
        //
        // Only when the two are different folders, which is exactly when `openAt` is set: a
        // path-addressed root lands on itself, and so does a source that opens at its own root.
        // Testing `openAt` rather than comparing the paths keeps that exact — the two strings can
        // only differ by the join, and a canonicalizing comparison would need the folder to exist
        // to answer, which is the very thing in question.
        if !provider.openAt.isEmpty {
            try requireDirectory(
                atPath: expandPath(provider.landingPath),
                fileManager: fileManager,
                missingMessage: "Provider '\(provider.displayName)' (\(label)) opens at '\(CLIOutput.verbatim(provider.openAt))', "
                    + "which does not exist under its root '\(CLIOutput.verbatim(provider.rootPath))'. "
                    + "Change the source's opening folder in Settings, or pass the folder as a path.",
                notDirectoryMessage: "Provider '\(provider.displayName)' (\(label)) opens at '\(CLIOutput.verbatim(provider.openAt))', "
                    + "which is not a directory."
            )
        }
        return provider
    }
    let expanded = expandPath(value)
    try requireDirectory(
        atPath: expanded,
        fileManager: fileManager,
        missingMessage: "Path or provider '\(CLIOutput.verbatim(value))' for \(label) could not be found.",
        notDirectoryMessage: "Path '\(CLIOutput.verbatim(expanded))' for \(label) is not a directory."
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
