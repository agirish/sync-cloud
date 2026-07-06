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

    @State private var computedDirectorySizePath: String? = nil
    @State private var computedDirectorySize: String? = nil

    /// Memoizes the metadata stat and NSWorkspace icon for the current path. Both hit the
    /// filesystem (slow on cloud paths), and this view re-renders on every syncManager change
    /// during bulk operations. A reference type held in @State: mutating it during body is a
    /// cache fill, not a state write, so it cannot re-trigger rendering.
    private final class MetadataCache {
        var path: String?
        var metadata: FileMetadata?
        var icon: NSImage?
    }
    @State private var cache = MetadataCache()

    /// Returns the memoized metadata/icon for `path`, refreshing the cache if the path changed
    /// or the cache was invalidated (after a file operation refresh).
    private func cachedData(for path: String) -> (metadata: FileMetadata?, icon: NSImage?) {
        if cache.path != path {
            cache.metadata = Self.loadMetadata(for: path)
            cache.icon = cache.metadata.map { NSWorkspace.shared.icon(forFile: $0.path) }
            cache.path = path
        }
        return (cache.metadata, cache.icon)
    }

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
        if let leftSelection = syncManager.selectedLeftPaths.sorted().first {
            return leftSelection
        } else if let rightSelection = syncManager.selectedRightPaths.sorted().first {
            return rightSelection
        }
        
        // Fallback to navigated folders
        return leftPath.isEmpty ? rightPath : leftPath
    }
    
    private static func loadMetadata(for activePath: String) -> FileMetadata? {
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
            let permStr = String(format: "%o", perms?.intValue ?? 0)
            
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

    private func displaySize(for data: FileMetadata) -> String {
        if !data.isDirectory { return data.size }

        if computedDirectorySizePath == data.path, let computedDirectorySize {
            return computedDirectorySize
        }
        return "Calculating…"
    }

    public var body: some View {
        // Metadata and icon are memoized per path (they hit the filesystem).
        let (data, icon) = cachedData(for: activePath)
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if let data {
                        // Icon Header
                        VStack {
                            Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: data.path))
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
                            metadataRow(label: "Size:", value: displaySize(for: data))
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
        .background(.regularMaterial.opacity(0.5))
        .ignoresSafeArea(.all, edges: .top) // Blend natively into the macOS Titlebar
        .clipped()
        .onReceive(syncManager.refreshSubject) { _ in
            // A file operation may have changed the selected item's attributes in place;
            // drop the memoized metadata so the next render re-stats it.
            cache.path = nil
        }
        .onReceive(syncManager.$isScanning) { scanning in
            // A completed scan is the "pick up external changes" gesture: the panes rebuild
            // from fresh stats, so the memoized metadata must not survive it — the sidebar
            // would keep showing pre-scan size/dates and contradict the trees.
            if !scanning { cache.path = nil }
        }
        .task(id: activePath) {
            guard let data, data.isDirectory else {
                computedDirectorySizePath = nil
                computedDirectorySize = nil
                return
            }

            // Avoid re-computing if we already have a cached value for this path.
            if computedDirectorySizePath == data.path, computedDirectorySize != nil {
                return
            }

            computedDirectorySizePath = data.path
            computedDirectorySize = nil

            let pathToCompute = data.path
            let result = await Self.computeDirectorySizeString(path: pathToCompute)

            guard !Task.isCancelled else { return }
            if computedDirectorySizePath == pathToCompute {
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
