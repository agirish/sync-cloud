import Foundation
import Sync

/// What Download offers for a selection — the row menu's question and File ▸ Download's, asked
/// once so the two cannot disagree (`PanePDFToolOffer`'s reason).
public enum CloudDownloadOffer: Equatable, Sendable {
    /// One file whose content is still in the cloud: **Download**.
    case file(path: String, name: String)
    /// Folders in a cloud location and cloud-only files, together: **Download All** — every
    /// cloud-only file among the files and at any depth below the folders.
    case all(files: [String], folders: [String])

    public var title: String {
        switch self {
        case .file: return "Download"
        case .all: return "Download All"
        }
    }

    /// The offer for `nodes`, or nil when nothing in them could be fetched.
    ///
    /// A folder is offered when it is in a cloud location — whether it holds anything cloud-only
    /// would take a walk to know. A file is offered when `isCloudOnly` says so; nil (not known yet)
    /// is not a yes.
    ///
    /// - Parameter isCloudOnly: the caller's answer for a file. The row menu asks the badge memo
    ///   and, for its own single row, a fresh `lstat`; File ▸ Download and a multi-selection ask
    ///   the memo alone — File ▸ on every window render, and a multi-selection's menu once per
    ///   selected row opened, each rebuilt with its row.
    /// - Parameter isInCloudLocation: a test's answer for a folder. The app's is
    ///   `MaterializationStatus.isInCloudLocation`, with its one attribute read — the domain of
    ///   `~/Desktop` or `~/Documents` — asked once per offer rather than once per selected folder:
    ///   two hundred folders selected in Documents would otherwise read the same attribute two
    ///   hundred times, on every selected row's render.
    /// - Parameter home: the home that app answer measures from — a test's scratch folder, so it
    ///   never reads below the real one (`FileContextMenu.cloudHome`).
    public static func forSelection(
        _ nodes: [FileNode],
        isCloudOnly: (String) -> Bool?,
        isInCloudLocation: ((String) -> Bool)? = nil,
        home: String = NSHomeDirectory()
    ) -> CloudDownloadOffer? {
        let isInCloudLocation = isInCloudLocation ?? {
            let domains = DomainMemo()
            return { MaterializationStatus.isInCloudLocation($0, home: home, domainOf: domains.domain(of:)) }
        }()
        if nodes.count == 1, let file = nodes.first, !file.isDirectory {
            return isCloudOnly(file.id) == true ? .file(path: file.id, name: file.name) : nil
        }
        let files = nodes.filter { !$0.isDirectory && isCloudOnly($0.id) == true }.map(\.id)
        let folders = nodes.filter { $0.isDirectory && isInCloudLocation($0.id) }.map(\.id)
        return files.isEmpty && folders.isEmpty ? nil : .all(files: files, folders: folders)
    }
}

extension CloudDownloadOffer {
    /// File ▸ Download's offer for the active pane's selection, asked on every `ContentView` body
    /// pass. A file is answered from the badge memo alone; a folder's cloud location — for one under
    /// `~/Desktop` or `~/Documents`, the attribute naming their File Provider domain, which is the
    /// read that hangs on a wedged provider — is read off the main thread (`BoundedCloudRead`). Nil
    /// when nothing could be fetched, and when the read did not answer in time.
    @MainActor
    public static func forActiveSelection(_ nodes: [FileNode]) -> CloudDownloadOffer? {
        let badges = nodes.reduce(into: [String: Bool]()) { known, node in
            if !node.isDirectory { known[node.id] = CloudOnlyBadgeCache.cached(node.id) }
        }
        return BoundedCloudRead.shared.run { forSelection(nodes, isCloudOnly: { badges[$0] }) } ?? nil
    }
}

/// What Keep Downloaded offers for a selection: its tick, and whether a click can change it.
struct KeepDownloadedOffer: Equatable, Sendable {
    /// Every item is kept — by its own pin or a folder's.
    let isOn: Bool
    /// Every item is kept by a folder above it, so no click here changes anything.
    let isLocked: Bool
    /// The folder keeping a single item, for the item's tooltip.
    let keptBy: String?

    /// Above this many items the multi-selection is not offered Keep Downloaded at all. The tick
    /// costs an `lstat` and a `getxattr` per item per level — ~9 µs, measured 2026-10-27 — and the
    /// menu waits for it at the right-click, and again whenever an opened row's menu is rebuilt with
    /// its row. Off the main thread now (`BoundedCloudRead`), but the wait is the same, and a read
    /// that outlives the deadline stops every menu's reads until it returns: 20 is well under a
    /// millisecond a level, where a selection of thousands could pass the 200 ms a wedge is told by.
    static let selectionCap = 20

    /// The offer for `nodes`, or nil when any of them is outside iCloud Drive (where the pin was
    /// measured ignored) or there are more than `selectionCap`.
    static func forSelection(_ nodes: [FileNode],
                             state: (String) -> KeepDownloaded.State) -> KeepDownloadedOffer? {
        guard !nodes.isEmpty, nodes.count <= selectionCap else { return nil }
        var states: [KeepDownloaded.State] = []
        for node in nodes {
            let one = state(node.id)
            if one == .unavailable { return nil }
            states.append(one)
        }
        let folders = states.compactMap { state -> String? in
            if case .inherited(let folder) = state { return folder }
            return nil
        }
        return KeepDownloadedOffer(
            isOn: !states.contains(.off),
            isLocked: folders.count == states.count,
            keptBy: states.count == 1 ? folders.first : nil)
    }
}

/// One offer's answers to "whose domain is this folder?" — see `CloudDownloadOffer.forSelection`.
private final class DomainMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: String?] = [:]

    @Sendable func domain(of folder: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = known[folder] { return hit }
        let answer = KeepDownloaded.realDomainOf(folder)
        known[folder] = answer
        return answer
    }
}
