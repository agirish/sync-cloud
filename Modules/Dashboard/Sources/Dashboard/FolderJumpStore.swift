import SwiftUI
import Foundation

/// One jump target within a provider pane: a folder to hop to, identified by its path relative to
/// the pane's provider root ("" is the root), plus the display name shown in the menu.
struct JumpLocation: Codable, Equatable, Identifiable, Hashable {
    let relativePath: String
    let name: String
    var id: String { relativePath }
}

/// Backs the pane header's folder quick-jump menu. Each pane already has back/forward history and an
/// up-the-tree breadcrumb — both move *up and back*. This adds the lateral hops they can't reach:
/// sibling folders (from disk), the folders you've recently visited (this session), and a curated
/// set of pins (persisted). Keyed by the pane's provider ROOT path — stable and unique per provider —
/// so both panes and relaunches agree for the same provider.
@MainActor
public final class FolderJumpStore: ObservableObject {
    public static let shared = FolderJumpStore()

    /// Recents are session-scoped (they mean "where I've been just now"), so they live in memory.
    @Published private(set) var recentsByRoot: [String: [JumpLocation]] = [:]
    /// Pins are curated and outlive the session, so they persist.
    @Published private(set) var pinnedByRoot: [String: [JumpLocation]] = [:]

    private let defaults: UserDefaults
    private static let pinnedKey = "folderJumpPinnedByRoot"
    static let maxRecents = 8

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pinnedKey),
           let decoded = try? JSONDecoder().decode([String: [JumpLocation]].self, from: data) {
            pinnedByRoot = decoded
        }
    }

    func recents(forRoot root: String) -> [JumpLocation] { recentsByRoot[root] ?? [] }
    func pinned(forRoot root: String) -> [JumpLocation] { pinnedByRoot[root] ?? [] }

    func isPinned(root: String, relativePath: String) -> Bool {
        (pinnedByRoot[root] ?? []).contains { $0.relativePath == relativePath }
    }

    /// Records a visited folder, moving it to the front and capping the list. The provider root
    /// itself is never "recent" — it is always one crumb click away — so an empty relative path is
    /// ignored.
    public func recordVisit(root: String, relativePath: String, name: String) {
        guard !relativePath.isEmpty, !name.isEmpty else { return }
        let visited = JumpLocation(relativePath: relativePath, name: name)
        recentsByRoot[root] = Self.inserting(visited, into: recentsByRoot[root] ?? [], cap: Self.maxRecents)
    }

    /// Pins or unpins a folder for its pane's provider. Pinning the folder that's already pinned
    /// removes it, so the same menu item toggles.
    func togglePin(root: String, relativePath: String, name: String) {
        var list = pinnedByRoot[root] ?? []
        if let index = list.firstIndex(where: { $0.relativePath == relativePath }) {
            list.remove(at: index)
        } else {
            list.append(JumpLocation(relativePath: relativePath, name: name))
        }
        pinnedByRoot[root] = list
        persistPinned()
    }

    private func persistPinned() {
        if let data = try? JSONEncoder().encode(pinnedByRoot) {
            defaults.set(data, forKey: Self.pinnedKey)
        }
    }

    /// Pure move-to-front dedupe + cap (newest first). Extracted so the recents ordering is testable
    /// without the store's persistence.
    static func inserting(_ location: JumpLocation, into list: [JumpLocation], cap: Int) -> [JumpLocation] {
        var result = list.filter { $0.relativePath != location.relativePath }
        result.insert(location, at: 0)
        return Array(result.prefix(cap))
    }
}

/// Filesystem side of the quick-jump menu: the current folder's sibling directories.
enum FolderJump {
    /// The immediate subfolders of the current folder's PARENT, excluding the current folder — the
    /// lateral hops neither the breadcrumb (up) nor back/forward (back) can reach. Returns an empty
    /// list at the pane root (no in-pane parent) or on any read error, and skips hidden folders.
    /// Names sort with the same localized-standard order the file panes use.
    static func siblings(rootPath: String, relativePath: String, fileManager: FileManager = .default) -> [JumpLocation] {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let currentName = components.last else { return [] } // "" → root has no in-pane parent
        let parentComponents = components.dropLast()
        let parentRelative = parentComponents.joined(separator: "/")
        let parentAbsolute = parentComponents.isEmpty ? rootPath : rootPath + "/" + parentRelative

        guard let entries = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: parentAbsolute),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> JumpLocation? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            guard name != currentName else { return nil }
            let relative = parentRelative.isEmpty ? name : parentRelative + "/" + name
            return JumpLocation(relativePath: relative, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The quick-jump menu hung off the current-folder crumb: pinned, recent, and sibling folders, plus
/// a pin toggle for the current folder. Reads the shared store and the filesystem lazily, only when
/// the menu opens.
struct FolderJumpMenu: View {
    let rootPath: String
    let relativePath: String
    let currentName: String
    let onNavigate: (String) -> Void

    @ObservedObject private var store = FolderJumpStore.shared

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Jump to a pinned, recent, or nearby folder")
        .accessibilityLabel("Jump to another folder")
    }

    @ViewBuilder
    private var content: some View {
        let pinned = store.pinned(forRoot: rootPath)
        // A recent entry for the folder you're already in would be a no-op — drop it.
        let recents = store.recents(forRoot: rootPath).filter { $0.relativePath != relativePath }
        let siblings = FolderJump.siblings(rootPath: rootPath, relativePath: relativePath)

        if pinned.isEmpty && recents.isEmpty && siblings.isEmpty {
            Text("No other folders")
        }
        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned) { jumpButton($0, pinned: true) }
            }
        }
        if !recents.isEmpty {
            Section("Recent") {
                ForEach(recents.prefix(6)) { jumpButton($0, pinned: store.isPinned(root: rootPath, relativePath: $0.relativePath)) }
            }
        }
        if !siblings.isEmpty {
            Section("Nearby folders") {
                ForEach(siblings.prefix(20)) { jumpButton($0, pinned: store.isPinned(root: rootPath, relativePath: $0.relativePath)) }
            }
        }

        Divider()
        let isCurrentPinned = store.isPinned(root: rootPath, relativePath: relativePath)
        Button {
            store.togglePin(root: rootPath, relativePath: relativePath, name: currentName)
        } label: {
            Label(isCurrentPinned ? "Unpin “\(currentName)”" : "Pin “\(currentName)”",
                  systemImage: isCurrentPinned ? "pin.slash" : "pin")
        }
        .disabled(relativePath.isEmpty) // the root is always reachable; pinning it adds nothing
    }

    private func jumpButton(_ location: JumpLocation, pinned: Bool) -> some View {
        Button {
            onNavigate(location.relativePath)
        } label: {
            Label(location.name, systemImage: pinned ? "star.fill" : "folder")
        }
    }
}
