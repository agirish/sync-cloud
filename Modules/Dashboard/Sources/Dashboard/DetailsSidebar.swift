import SwiftUI
import Sync
import UniformTypeIdentifiers

/// A native SwiftUI Details Sidebar that displays rich file metadata.
/// Integrated into the bottom tabbed workspace of the `ContentView`.
/// It provides fallback information for the currently navigated folder when no specific file is selected.
public struct DetailsSidebar: View {
    @ObservedObject public var syncManager: FileSyncManager
    
    /// Contextual folder paths for fallback.
    public let leftPath: String
    public let rightPath: String

    @State private var computedDirectorySizePath: String? = nil
    @State private var computedDirectorySize: String? = nil
    
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
    
    /// The absolute path of the file or folder currently being inspected.
    /// Prioritizes explicit tree selection, falling back to the currently navigated folder (Left or Right).
    internal var activePath: String {
        if let leftSelection = syncManager.selectedLeftPaths.sorted().first {
            return leftSelection
        } else if let rightSelection = syncManager.selectedRightPaths.sorted().first {
            return rightSelection
        }
        
        // Fallback to navigated folders
        return leftPath.isEmpty ? rightPath : leftPath
    }
    
    private var metadata: FileMetadata? {
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
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .medium
            
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

    private var displaySize: String {
        guard let data = metadata else { return "" }
        if !data.isDirectory { return data.size }

        if computedDirectorySizePath == data.path, let computedDirectorySize {
            return computedDirectorySize
        }
        return "Calculating…"
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if let data = metadata {
                    // Icon Header
                    VStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: data.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .padding(.top, 16)
                    Spacer()
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
                    metadataRow(label: "Size:", value: displaySize)
                    metadataRow(label: "Where:", value: data.path)
                    
                    Divider()
                    
                    metadataRow(label: "Created:", value: data.creationDate)
                    metadataRow(label: "Modified:", value: data.modificationDate)
                    
                    Divider()
                    
                    metadataRow(label: "Permissions:", value: data.permissions)
                    
                    Spacer()
                }
                .padding(.trailing, 20)
                
                Spacer()
            } else {
                VStack {
                    Spacer()
                    Text("No item selected or item is unavailable.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        }
        .padding()
        // Allow the sidebar to shrink slightly but wrap text elements to avoid clipping
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        .ignoresSafeArea(.all, edges: .top) // Blend natively into the macOS Titlebar
        .clipped()
        .task(id: activePath) {
            guard let data = metadata, data.isDirectory else {
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
