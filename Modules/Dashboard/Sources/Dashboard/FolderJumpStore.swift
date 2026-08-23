import SwiftUI
import Foundation
import Events

/// One jump target within a provider pane: a folder to hop to, identified by its path relative to
/// the pane's provider root ("" is the root), plus the display name shown in the menu. `Sendable`
/// so the sibling enumeration can hand results back from a detached (off-main) task.
struct JumpLocation: Codable, Equatable, Identifiable, Hashable, Sendable {
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
            // Re-keyed on the way in. Pins written before this store normalised its keys sit under
            // whatever spelling the writer happened to hold — `~/Documents` for a folder source —
            // and reading them back through `key(forRoot:)` would miss every one of them. A fix
            // that makes existing pins reachable must not begin by orphaning them.
            //
            // **Deduplicated as they merge, because the bug being repaired is what creates the
            // duplicates.** A folder pinned from the breadcrumb read as unpinned in the pane, so
            // pinning it again there was the obvious thing to do — and wrote a second entry for the
            // same folder under the other spelling. Concatenating the two lists lands that folder
            // twice on exactly the installs this migration exists for: the ⌘K palette then lists it
            // twice, and one unpin peels off one copy and leaves it pinned.
            //
            // Keys taken in sorted order so the merged ORDER is the same on every launch —
            // dictionary iteration is not, and pins are shown in the order they are held.
            pinnedByRoot = decoded.keys.sorted().reduce(into: [:]) { out, rawKey in
                let key = Self.key(forRoot: rawKey)
                var list = out[key] ?? []
                for pin in decoded[rawKey] ?? []
                where !list.contains(where: { $0.relativePath == pin.relativePath }) {
                    list.append(pin)
                }
                out[key] = list
            }
        }
    }

    /// **The one place a provider root becomes a key.** Every entry point below routes through it,
    /// so a caller holding either spelling of the same root reaches the same entry.
    ///
    /// A folder source's path keeps its `~`, and the app carries both forms: the panes and the
    /// breadcrumb hand over `settings.path(for:)` as stored, while surfaces that touch the disk
    /// expand it first. Used raw as dictionary keys, those two never met — a folder pinned from the
    /// breadcrumb was missing from every reader holding the expanded form, and "no pins" is exactly
    /// what an unpinned provider looks like, so nothing said so.
    ///
    /// Expansion plus a trailing-slash trim, and deliberately no more: case-folding would merge two
    /// genuinely distinct roots on a case-sensitive volume, and symlink resolution would make a key
    /// depend on disk state that can change under a persisted pin.
    static func key(forRoot root: String) -> String {
        var path = (root as NSString).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func recents(forRoot root: String) -> [JumpLocation] { recentsByRoot[Self.key(forRoot: root)] ?? [] }
    func pinned(forRoot root: String) -> [JumpLocation] { pinnedByRoot[Self.key(forRoot: root)] ?? [] }

    func isPinned(root: String, relativePath: String) -> Bool {
        (pinnedByRoot[Self.key(forRoot: root)] ?? []).contains { $0.relativePath == relativePath }
    }

    /// Records a visited folder, moving it to the front and capping the list. The provider root
    /// itself is never "recent" — it is always one crumb click away — so an empty relative path is
    /// ignored.
    public func recordVisit(root: String, relativePath: String, name: String) {
        guard !relativePath.isEmpty, !name.isEmpty else { return }
        let visited = JumpLocation(relativePath: relativePath, name: name)
        let key = Self.key(forRoot: root)
        recentsByRoot[key] = Self.inserting(visited, into: recentsByRoot[key] ?? [], cap: Self.maxRecents)
    }

    /// Pins or unpins a folder for its pane's provider. Pinning the folder that's already pinned
    /// removes it, so the same menu item toggles.
    func togglePin(root: String, relativePath: String, name: String) {
        let key = Self.key(forRoot: root)
        var list = pinnedByRoot[key] ?? []
        // `removeAll`, not `remove(at: firstIndex)`: a list written before the keys were normalised
        // can hold the same folder twice (see `init`), and peeling off one copy leaves the folder
        // pinned after the user asked for it not to be. The migration dedupes what it reads, so
        // this is belt and braces — and it is the half that also protects a store built in memory.
        let before = list.count
        list.removeAll { $0.relativePath == relativePath }
        if list.count == before {
            list.append(JumpLocation(relativePath: relativePath, name: name))
        }
        pinnedByRoot[key] = list
        persistPinned()
    }

    private func persistPinned() {
        if let data = try? JSONEncoder().encode(pinnedByRoot) {
            defaults.set(data, forKey: Self.pinnedKey)
        } else {
            // The read side treats unreadable bytes as a state worth preserving; a write that
            // silently skips is the same loss one step earlier, so it at least gets a line.
            Logger.shared.error("The pinned-folders list could not be encoded for saving — the previously stored list is left in place")
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
    /// list at the pane root (no in-pane parent) or on any read error. Honors the pane's
    /// show-hidden-files setting so the jump menu matches what the pane shows. Names sort with the
    /// same localized-standard order the file panes use. `nonisolated` and pure so it can run off
    /// the main thread (a large cloud directory would otherwise jank the menu-open).
    nonisolated static func siblings(rootPath: String, relativePath: String, showHidden: Bool = false, fileManager: FileManager = .default, logError: (@Sendable (String) -> Void)? = nil) -> [JumpLocation] {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let currentName = components.last else { return [] } // "" → root has no in-pane parent
        let parentComponents = components.dropLast()
        let parentRelative = parentComponents.joined(separator: "/")
        let parentAbsolute = parentComponents.isEmpty ? rootPath : rootPath + "/" + parentRelative

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: parentAbsolute),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: showHidden ? [] : [.skipsHiddenFiles])
        } catch {
            // Don't silently read as "no other folders" — a permission/IO failure is worth a
            // breadcrumb (debug level: this can fire on every menu-open). Logged via the injected
            // closure because this runs off-main and `Logger.shared` is main-actor isolated; the
            // caller captures it on the main actor.
            logError?("Folder jump: couldn't list siblings under \(parentAbsolute): \(error.localizedDescription)")
            return []
        }

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
    /// The pane's live show-hidden-files state, so the menu's siblings match what the pane lists.
    let showHidden: Bool
    let onNavigate: (String) -> Void

    @ObservedObject private var store = FolderJumpStore.shared
    /// Sibling folders, enumerated OFF the main thread whenever the current folder (or the
    /// show-hidden setting) changes, so opening the menu never blocks on a large cloud directory.
    @State private var siblings: [JumpLocation] = []

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "chevron.down")
                .scaledFont(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Jump to a pinned, recent, or nearby folder")
        .accessibilityLabel("Jump to another folder")
        .task(id: "\(rootPath)|\(relativePath)|\(showHidden)") {
            let root = rootPath, rel = relativePath, hidden = showHidden
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            siblings = await Task.detached(priority: .userInitiated) {
                FolderJump.siblings(rootPath: root, relativePath: rel, showHidden: hidden,
                                    logError: { logger.debug($0) })
            }.value
        }
    }

    @ViewBuilder
    private var content: some View {
        let pinned = store.pinned(forRoot: rootPath)
        // A recent entry for the folder you're already in would be a no-op — drop it.
        let recents = store.recents(forRoot: rootPath).filter { $0.relativePath != relativePath }
        // `siblings` is the pre-loaded @State (scanned off-main on folder change), not a fresh
        // synchronous directory read at menu-open time.

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
