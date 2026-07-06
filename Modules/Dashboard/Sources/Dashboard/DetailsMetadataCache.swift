import AppKit

/// Memoizes the metadata stat and NSWorkspace icon for the details sidebar's current path,
/// plus the two invalidation decisions, extracted from DetailsSidebar's view body so the
/// rules are unit-testable.
///
/// Both loads hit the filesystem (slow on cloud paths), and the sidebar re-renders on every
/// syncManager change during bulk operations. A reference type held in @State: mutating it
/// during body is a cache fill, not a state write, so it cannot re-trigger rendering.
@MainActor
final class DetailsMetadataCache {
    private let loadMetadata: @MainActor (String) -> DetailsSidebar.FileMetadata?
    private let loadIcon: @MainActor (String) -> NSImage

    private var path: String?
    private var metadata: DetailsSidebar.FileMetadata?
    private var icon: NSImage?

    init(
        loadMetadata: @escaping @MainActor (String) -> DetailsSidebar.FileMetadata? = DetailsSidebar.loadMetadata(for:),
        loadIcon: @escaping @MainActor (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.loadMetadata = loadMetadata
        self.loadIcon = loadIcon
    }

    /// Returns the memoized metadata/icon for `path`, refreshing the cache if the path changed
    /// or the cache was invalidated. A nil stat result (missing path) is memoized too, so an
    /// unavailable item doesn't get re-statted on every render.
    func data(for path: String) -> (metadata: DetailsSidebar.FileMetadata?, icon: NSImage?) {
        if self.path != path {
            metadata = loadMetadata(path)
            icon = metadata.map { loadIcon($0.path) }
            self.path = path
        }
        return (metadata, icon)
    }

    /// A file operation may have changed the current item's attributes in place; drop the
    /// memoized metadata so the next lookup re-stats it.
    func refreshOccurred() {
        path = nil
    }

    /// A completed scan is the "pick up external changes" gesture: the panes rebuild from
    /// fresh stats, so the memoized metadata must not survive it — the sidebar would keep
    /// showing pre-scan size/dates and contradict the trees. Only `isScanning == false`
    /// invalidates; a scan *starting* keeps the cache.
    func scanningChanged(_ isScanning: Bool) {
        if !isScanning { path = nil }
    }
}
