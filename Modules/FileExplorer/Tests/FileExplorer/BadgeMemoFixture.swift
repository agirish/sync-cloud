import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The pane fixture and the two instruments that `RiskyNameBadgeMemoTests` (the tree pane) and
/// `RiskyNameBadgeColumnsMemoTests` (the columns pane) both measure against.
///
/// Shared rather than duplicated because the claim being enforced is one claim — the rules run once
/// per distinct name, whichever presentation is asking — and two copies of a 60-row fixture would
/// drift apart exactly where the two panes are supposed to agree.
@MainActor
enum BadgeMemoFixture {

    static let root = "/root"

    /// Every fixture name starts with this. The memo is process-wide and shared with
    /// `DifferencesView`, so the token is what makes "evaluations of MY names" a well-defined
    /// quantity no other suite can contribute to — including `RiskyNameBadgePredicateTests`, whose
    /// fixtures would otherwise overlap these almost exactly.
    static let token = "memo-"

    /// The names the visible rows draw from. Deliberately fewer than the rows that show them: the
    /// memo's premise is that names repeat heavily, and a fixture of all-distinct names could not
    /// tell a per-name memo from a per-row one.
    ///
    /// Three of the twelve are risky — a trailing space, a colon, a zero-width character — so the
    /// badge actually draws on some rows rather than the whole pane taking the "nothing to show"
    /// path. The token prefix changes none of those verdicts.
    static let visibleFileNames = [
        "\(token)Statement 2026.pdf", "\(token)notes.txt", "\(token)Q3 final.pdf", "\(token)archive.zip",
        "\(token)receipt ", "\(token)photo.heic", "\(token)Q3: final.pdf", "\(token)budget.numbers",
        "\(token)read\u{200B}me.txt", "\(token)index.md", "\(token)cover.png", "\(token)invoice.pdf",
    ]

    /// Folder rows, visible alongside the files and unopened. Their own names are asked about;
    /// their children's must not be.
    static let visibleFolderNames = ["\(token)Taxes", "\(token)Scans", "\(token)Archive"]

    /// Every distinct name a correctly-memoized pane may evaluate for this fixture.
    static var visibleDistinctNames: Set<String> {
        Set(visibleFileNames).union(visibleFolderNames)
    }

    static let hiddenPrefix = "\(token)hidden-"

    /// The id of the nth file row, for driving a selection change.
    static func fileID(_ index: Int) -> String {
        "\(root)/f\(index)-\(visibleFileNames[index % visibleFileNames.count])"
    }

    /// Rows drawn from `visibleFileNames`, five times round, so 60 rows carry 12 names. `id` is the
    /// only thing that distinguishes two rows with the same name — which is exactly the shape a
    /// per-row or per-path key would fail on.
    private static func visibleFiles() -> [FileNode] {
        (0..<60).map { i in
            FileNode(id: fileID(i), name: visibleFileNames[i % visibleFileNames.count], isDirectory: false)
        }
    }

    /// Folders holding 600 names that appear NOWHERE among the visible rows, and that neither
    /// presentation shows until it is asked to: the tree pane's `OutlineGroup` does not build a
    /// collapsed row's children, and the columns pane opens a folder's column only on a drill. So a
    /// pane that stays lazy never sees these; anything that walks the published tree sees all 600.
    private static func hiddenFolders() -> [FileNode] {
        visibleFolderNames.enumerated().map { index, folder in
            let children = (0..<200).map { j in
                FileNode(id: "\(root)/\(folder)/\(hiddenPrefix)\(index)-\(j).pdf",
                         name: "\(hiddenPrefix)\(index)-\(j).pdf", isDirectory: false)
            }
            return FileNode(id: "\(root)/\(folder)", name: folder, isDirectory: true, children: children)
        }
    }

    static func tree(side: PaneTree.Side) -> PaneTree {
        PaneTree(side: side, version: 1, nodes: hiddenFolders() + visibleFiles())
    }
}

/// Records the names the rules actually ran for, ignoring every name that is not this fixture's.
///
/// `@MainActor` explicitly: the memo it observes and the panes it observes them from are all
/// main-actor bound.
@MainActor
final class BadgeEvaluationLog {
    private(set) var names: [String] = []

    /// Installs itself as the cache's observer for the duration of `body`, and unhooks after — an
    /// observer left behind would attribute the next case's evaluations to this one.
    static func record(_ body: (BadgeEvaluationLog) -> Void) {
        let log = BadgeEvaluationLog()
        RiskyNameBadgeCache.onEvaluateForTesting = { name in
            guard name.hasPrefix(BadgeMemoFixture.token) else { return }
            log.names.append(name)
        }
        defer { RiskyNameBadgeCache.onEvaluateForTesting = nil }
        body(log)
    }

    var count: Int { names.count }

    /// Evaluations of names no visible row carries — an eager walk's signature, and the one thing a
    /// count alone cannot distinguish from honest work.
    var strays: [String] {
        names.filter { !BadgeMemoFixture.visibleDistinctNames.contains($0) }
    }
}

/// Routes `riskyNameReason` through the memo exactly as `PaneActionDelegate` does, and records
/// every name it was asked about.
///
/// A class, not a struct: the panes hold this as an existential and the recording has to survive
/// being copied into the view graph.
final class BadgeRecordingDelegate: FileActionDelegate {
    let provider: CloudProvider.ProviderType
    /// Every ask, in order and with repeats — `count` is the traffic the pane generates,
    /// `Set(…).count` is what the memo is allowed to charge for.
    private(set) var asked: [String] = []

    init(provider: CloudProvider.ProviderType) { self.provider = provider }

    func handleRefresh() {}
    func handleOpenInEditor(_ path: String) {}
    func handleFocus(_ node: FileNode) {}
    func handleCopy(_ nodes: [FileNode]) {}
    func handleMove(_ nodes: [FileNode]) {}
    func handleDelete(_ nodes: [FileNode]) {}
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
    func handlePaste(_ targetDir: FileNode) {}
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
    func handlePasteToPath(_ path: String) {}
    func handleRename(_ node: FileNode) {}
    func handleCreateFolder(at path: String) {}
    func handleGetInfo(for path: String) {}
    func handleSort(_ option: SortOption) {}
    func handleIgnore(_ nodes: [FileNode]) {}
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }

    /// No kept-name short-circuit, unlike production: it would let a name be asked about without
    /// reaching the memo, and these cases compare the two counts directly.
    func riskyNameReason(forName name: String, isDirectory: Bool) -> String? {
        MainActor.assumeIsolated {
            asked.append(name)
            return RiskyNameBadgeCache.reason(name: name, isDirectory: isDirectory, provider: provider)
        }
    }
}

/// Mounting and pumping helpers shared by both memo suites.
@MainActor
enum BadgeMemoMount {

    /// Wraps `content` in a window sized like a real pane.
    ///
    /// `isReleasedWhenClosed` is forced false: `NSWindow` defaults it to true, and `close()` then
    /// drops a reference ARC still owns — a segfault at the end of the first mounted case, not a
    /// test failure. Each case does close its window rather than leaving live panes on the main
    /// actor for whatever runs next in this target.
    static func window<Content: View>(_ content: Content, height: CGFloat = 700) -> NSWindow {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    /// Settles the mount. Not a measurement — no deadline here decides anything, so a slow machine
    /// only makes this take longer, never makes it wrong.
    static func settle(_ window: NSWindow, seconds: Double = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }

    /// One full re-render of the pane and every visible row of it — the click a user pays for, and
    /// the pass the badge rides on.
    static func renderPass(_ window: NSWindow, _ apply: () -> Void) {
        apply()
        window.layoutIfNeeded()
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
        window.layoutIfNeeded()
    }
}
