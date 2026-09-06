import Events
import Foundation

// MARK: - Pre-write destination-name check
//
// Every transfer entry point (`syncFile`, `transferItems`, `syncAll`) runs the destination
// through this check before any I/O. A name the destination provider forbids (e.g. a
// trailing space on Dropbox) would be written locally just fine — and then never uploaded,
// leaving an identical-looking, local-only duplicate next to the provider-normalized
// original. The check surfaces the `invalidNameResolver` prompt offering a sanitized name;
// an accepted sanitized name that collides with an existing item then flows through the
// normal collision machinery.

extension FileSyncManager {

    /// Outcome of the pre-write name check for one destination URL.
    enum DestinationNameDecision: Equatable {
        /// The name is acceptable to the destination provider (or the destination isn't
        /// inside a known provider root); write as planned.
        case clean
        /// The user chose the sanitized name; write to this URL instead.
        case sanitized(URL)
        /// The user insisted on the original, provider-invalid name.
        case keepOriginal
        /// The user skipped this item; write nothing.
        case skip
    }

    /// The scanned pane provider owning `path`, or nil when the path lies outside both roots.
    nonisolated static func destinationProvider(
        forPath path: String,
        providers: (left: CloudProvider, right: CloudProvider)?,
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders
    ) -> CloudProvider? {
        guard let providers else { return nil }
        for provider in [providers.left, providers.right] {
            let root = PathBoundary.normalizedRoot(provider.rootPath)
            guard !root.isEmpty else { continue }
            // Boundary-safe on "/", and aware of the folders a root links in from outside (iCloud
            // Drive's `~/Documents`), which a prefix test would place outside both panes.
            if PathBoundary.contains(path, under: root, links: links) { return provider }
        }
        return nil
    }

    /// The pure core: the prompt describing why `url`'s provider rejects its name, plus the
    /// sanitized URL to offer — or nil when the name is acceptable (or not attributable to a
    /// provider). Static and value-in/value-out so `transferItems`' detached worker can call
    /// it with captured snapshots.
    nonisolated static func nameViolationPrompt(
        forDestination url: URL,
        providers: (left: CloudProvider, right: CloudProvider)?,
        isMove: Bool
    ) -> (prompt: NameViolationPrompt, sanitizedURL: URL)? {
        guard let provider = destinationProvider(forPath: url.path, providers: providers) else { return nil }
        var root = (provider.rootPath as NSString).expandingTildeInPath
        while root.hasSuffix("/") { root.removeLast() }
        let destinationPath = url.path
        guard destinationPath != root else { return nil }
        let relativePath = String(destinationPath.dropFirst(root.count + 1))
        guard let violation = ProviderNameRules.violation(inRelativePath: relativePath, for: provider.type) else {
            return nil
        }
        let sanitizedRelative = ProviderNameRules.sanitizedRelativePath(relativePath, for: provider.type)
        let sanitizedURL = URL(fileURLWithPath: (root as NSString).appendingPathComponent(sanitizedRelative))
        let prompt = NameViolationPrompt(
            itemName: violation.componentName,
            sanitizedName: violation.sanitizedName,
            providerName: provider.displayName,
            reason: violation.reason,
            destinationPath: destinationPath,
            isMove: isMove
        )
        return (prompt, sanitizedURL)
    }

    /// Checks one destination against its provider's name rules, consulting the
    /// `invalidNameResolver` when they reject it, and logs the outcome. MainActor because the
    /// resolver presents UI; the detached transfer loop hops here via `MainActor.run`.
    func checkDestinationName(for url: URL, isMove: Bool) -> DestinationNameDecision {
        guard let (prompt, sanitizedURL) = Self.nameViolationPrompt(
            forDestination: url,
            providers: lastScanProviders,
            isMove: isMove
        ) else { return .clean }

        switch invalidNameResolver(prompt) {
        case .useSanitizedName:
            Logger.shared.info(
                "Destination name \"\(prompt.itemName)\" is not allowed by \(prompt.providerName); "
                + "writing as \"\(prompt.sanitizedName)\" instead")
            return .sanitized(sanitizedURL)
        case .keepOriginalName:
            Logger.shared.warning(
                "Writing \"\(prompt.itemName)\" to \(prompt.providerName) despite its name rules "
                + "(user's choice) — the item may stay local-only: \(prompt.destinationPath)")
            return .keepOriginal
        case .skip:
            Logger.shared.warning(
                "Skipped writing \"\(prompt.itemName)\": \(prompt.reason) (\(prompt.destinationPath))")
            return .skip
        }
    }
}
