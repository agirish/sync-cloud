import SwiftUI
import Sync
import Combine
import UniformTypeIdentifiers

/// Sidebar that shows file/folder metadata (size, dates, permissions) for the current selection or focused folder.
/// Shown in the bottom tabbed area of the main view when the “Details” tab is selected.
public struct DetailsSidebar: View {
    @ObservedObject public var syncManager: FileSyncManager

    /// Current root path for the left pane (used when no item is selected).
    public let leftPath: String
    /// Current root path for the right pane (used when no item is selected).
    public let rightPath: String

    @State private var computedDirectorySizeKey: DirectorySizeTaskID? = nil
    @State private var computedDirectorySize: String? = nil
    /// Mirror of `cache.generation` (the cache is a plain class in @State, so mutating it can't
    /// re-trigger rendering); updated in the same onReceive closures that invalidate the cache,
    /// so the size task's id changes and it recomputes.
    @State private var sizeGeneration = 0

    /// Memoization and invalidation rules live in DetailsMetadataCache; the view only
    /// forwards lookups and the refresh/scan events to it.
    @State private var cache = DetailsMetadataCache()

    /// Shared formatter for created/modified dates. Reused instead of reallocated on every access
    /// of `metadata` (DateFormatter is expensive to construct).
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
    
    public init(syncManager: FileSyncManager, leftPath: String, rightPath: String) {
        self.syncManager = syncManager
        self.leftPath = leftPath
        self.rightPath = rightPath
    }
    
    // Internal struct to hold parsed metadata logic cleanly.
    struct FileMetadata {
        let name: String
        let path: String
        let kind: String
        let size: String
        let creationDate: String
        let modificationDate: String
        let permissions: String
        let isDirectory: Bool
    }
    
    /// The path to display metadata for: first selected path in either pane, or the focused folder path.
    internal var activePath: String {
        // `min()` is the allocation-free equivalent of `sorted().first` — the alphabetically
        // first selected path (left pane first), matching `PaneLogic.primarySelectionPath`.
        if let leftSelection = syncManager.selectedLeftPaths.min() {
            return leftSelection
        } else if let rightSelection = syncManager.selectedRightPaths.min() {
            return rightSelection
        }
        
        // Fallback to navigated folders
        return leftPath.isEmpty ? rightPath : leftPath
    }

    /// Non-nil when 2+ items are selected: the sidebar shows the Finder-style summary instead
    /// of single-item metadata (which would silently describe only the alphabetically-first
    /// path). Left pane wins when both have selections — the same rule as `activePath`.
    internal var selectionSummary: DetailsSelectionSummary? {
        if !syncManager.selectedLeftPaths.isEmpty {
            return DetailsSelectionSummary.make(selectedPaths: syncManager.selectedLeftPaths, in: syncManager.leftTree)
        }
        return DetailsSelectionSummary.make(selectedPaths: syncManager.selectedRightPaths, in: syncManager.rightTree)
    }

    /// `.task(id:)` key for the directory-size walk. Includes the multi-selection flag so the
    /// task re-fires when the selection collapses back to one item with the same `activePath`
    /// (the size was cleared while multi-selected and must recompute), and the cache generation
    /// so a refresh/scan-end drops the stale total and recomputes it.
    private struct DirectorySizeTaskID: Equatable {
        let path: String
        let isMultiSelection: Bool
        let generation: Int
    }

    static func loadMetadata(for activePath: String) -> FileMetadata? {
        let url = URL(fileURLWithPath: activePath)
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: activePath, isDirectory: &isDir) else { return nil }

        do {
            let attrs = try fm.attributesOfItem(atPath: activePath)
            
            // Name
            let name = url.lastPathComponent
            
            // Dates
            let creation = attrs[.creationDate] as? Date ?? Date.distantPast
            let modification = attrs[.modificationDate] as? Date ?? Date.distantPast

            let dateFormatter = Self.dateFormatter

            // Size
            let sizeInt = attrs[.size] as? Int64 ?? 0
            let sizeStr = isDir.boolValue ? "" : ByteCountFormatter.string(fromByteCount: sizeInt, countStyle: .file)
            
            // Permissions
            let perms = attrs[.posixPermissions] as? NSNumber
            let permStr = symbolicPermissions(mode: perms?.intValue ?? 0, isDirectory: isDir.boolValue)
            
            // Kind
            var fileKind = isDir.boolValue ? "Folder" : "Document"
            if let typeID = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
                if let localized = UTType(typeID)?.localizedDescription {
                    fileKind = localized
                }
            }
            
            return FileMetadata(
                name: name,
                path: activePath,
                kind: fileKind,
                size: sizeStr,
                creationDate: dateFormatter.string(from: creation),
                modificationDate: dateFormatter.string(from: modification),
                permissions: permStr,
                isDirectory: isDir.boolValue
            )
        } catch {
            return nil
        }
    }

    /// Renders a POSIX mode as an `ls`-style symbolic string followed by the octal in
    /// parentheses, e.g. mode `0o755` on a directory → `"drwxr-xr-x (755)"`.
    ///
    /// The leading char is `d` for a directory and `-` for a file, followed by the
    /// owner/group/other `rwx` triads. Special bits are honoured: setuid/setgid show
    /// `s` in the owner/group execute slot (`S` when the execute bit is unset), and the
    /// sticky bit shows `t` in the other-execute slot (`T` when unset). The mode is
    /// masked with `0o7777`, so the parenthesised octal includes any special bits
    /// (e.g. `0o4755` → `"-rwsr-xr-x (4755)"`). Pure formatting; no I/O.
    nonisolated static func symbolicPermissions(mode: Int, isDirectory: Bool) -> String {
        let m = mode & 0o7777
        let octal = String(format: "%03o", m)

        // Builds one rwx triad. `specialBit` is the setuid/setgid/sticky mask for this
        // triad and `specialChar` its lowercase glyph (`s` or `t`); it renders in the
        // execute slot, uppercased when the underlying execute bit is unset.
        func triad(shift: Int, specialBit: Int, specialChar: Character) -> String {
            let bits = (m >> shift) & 0o7
            let r = (bits & 0o4) != 0 ? "r" : "-"
            let w = (bits & 0o2) != 0 ? "w" : "-"
            let executable = (bits & 0o1) != 0
            let x: String
            if (m & specialBit) != 0 {
                x = executable ? String(specialChar) : specialChar.uppercased()
            } else {
                x = executable ? "x" : "-"
            }
            return r + w + x
        }

        let type = isDirectory ? "d" : "-"
        let owner = triad(shift: 6, specialBit: 0o4000, specialChar: "s")
        let group = triad(shift: 3, specialBit: 0o2000, specialChar: "s")
        let other = triad(shift: 0, specialBit: 0o1000, specialChar: "t")

        return "\(type)\(owner)\(group)\(other) (\(octal))"
    }

    /// `key` matches on generation too, so an invalidated total shows "Calculating…" while the
    /// re-keyed task recomputes it instead of serving the pre-operation value.
    private func displaySize(for data: FileMetadata, key: DirectorySizeTaskID) -> String {
        if !data.isDirectory { return data.size }

        if computedDirectorySizeKey == key, let computedDirectorySize {
            return computedDirectorySize
        }
        return "Calculating…"
    }

    public var body: some View {
        let summary = selectionSummary
        // Metadata and icon are memoized per path (they hit the filesystem). A multi-selection
        // renders the summary instead, so the single-item lookup is skipped entirely.
        let (data, icon): (FileMetadata?, NSImage?) = summary == nil ? cache.data(for: activePath) : (nil, nil)
        let sizeKey = DirectorySizeTaskID(path: activePath, isMultiSelection: summary != nil, generation: sizeGeneration)
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if let summary {
                        // Stack-of-documents header mirroring the single-item icon column.
                        VStack {
                            Image(systemName: "square.fill.on.square.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 56, height: 56)
                                .foregroundStyle(.secondary)
                                .padding(.top, 28)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 120)

                        VStack(alignment: .leading, spacing: 12) {
                            Text(summary.title)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .padding(.top, 10)

                            Divider()

                            metadataRow(label: "Items:", value: summary.kindDescription)
                            metadataRow(label: "Size:", value: summary.sizeDescription)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 20)

                        Spacer(minLength: 0)
                    // The cache loads the icon whenever the metadata stat succeeds, so `icon`
                    // is non-nil exactly when `data` is — one binding, no fallback icon path.
                    } else if let data, let icon {
                        // Icon Header
                        VStack {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .padding(.top, 16)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 120)
                        
                        // Metadata Table
                        VStack(alignment: .leading, spacing: 12) {
                            Text(data.name)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.top, 10)
                            
                            Divider()
                            
                            metadataRow(label: "Kind:", value: data.kind)
                            metadataRow(label: "Size:", value: displaySize(for: data, key: sizeKey))
                            metadataRow(label: "Where:", value: data.path)
                            
                            Divider()
                            
                            metadataRow(label: "Created:", value: data.creationDate)
                            metadataRow(label: "Modified:", value: data.modificationDate)
                            
                            Divider()
                            
                            metadataRow(label: "Permissions:", value: data.permissions)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 20)
                        
                        Spacer(minLength: 0)
                    } else {
                        VStack {
                            Spacer(minLength: 0)
                            Text("No item selected or item is unavailable.")
                                .foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 120)
                    }
                }
            }
            .padding(20)
        }
        .frame(minHeight: 0)
        // Allow the sidebar to shrink slightly but wrap text elements to avoid clipping
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .onReceive(syncManager.refreshSubject) { _ in
            cache.refreshOccurred()
            sizeGeneration = cache.generation
        }
        .onReceive(syncManager.$isScanning) { scanning in
            cache.scanningChanged(scanning)
            sizeGeneration = cache.generation
        }
        .task(id: sizeKey) {
            // No directory walk while multi-selected: the summary never shows a computed
            // folder size (it stays metadata-only).
            guard summary == nil, let data, data.isDirectory else {
                computedDirectorySizeKey = nil
                computedDirectorySize = nil
                return
            }

            // Avoid re-computing if we already have a cached value for this key (same path,
            // same generation, single-selection).
            if computedDirectorySizeKey == sizeKey, computedDirectorySize != nil {
                return
            }

            computedDirectorySizeKey = sizeKey
            computedDirectorySize = nil

            let result = await Self.computeDirectorySizeString(path: data.path)

            guard !Task.isCancelled else { return }
            if computedDirectorySizeKey == sizeKey {
                computedDirectorySize = result ?? "--"
            }
        }
    }

    nonisolated private static func computeDirectorySizeString(path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return nil
        }

        var total: Int64 = 0
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            // Check for cancellation periodically to avoid orphaned background work
            if count % 100 == 0 {
                if Task.isCancelled { return nil }
                await Task.yield()
            }
            count += 1
            
            autoreleasepool {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let size = values.fileSize
                else {
                    return
                }
                total += Int64(size)
            }
        }

        if Task.isCancelled { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            
            // Allow text to wrap across multiple lines
            Text(value)
                .textSelection(.enabled) 
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
