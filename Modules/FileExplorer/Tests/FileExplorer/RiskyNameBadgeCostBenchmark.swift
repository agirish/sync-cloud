import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// What the row badge costs the pane — the app's tightest render path, and the one place the brief
/// for this feature said not to add work blind.
///
/// **Interleaved, not sequential.** The two arms alternate within a single run and their samples are
/// reported with their spread. A sequential A/B on this machine has lied before: it is also the CI
/// runner, other sessions build on it, and a batch of samples taken a minute apart can differ by
/// more than the effect being measured. Alternating puts both arms under the same load.
///
/// The arms differ in exactly one thing — whether the delegate answers `riskyNameReason` — so the
/// difference is the badge's own cost: the memo lookup per visible row, plus drawing the glyph on
/// the rows that earn one.
///
/// Inert unless `SYNCCLOUD_BADGE_BENCHMARK=1`, so an ordinary `swift test` and CI never run it:
///
/// ```sh
/// SYNCCLOUD_BADGE_BENCHMARK=1 arch -arm64 swift test -c release --filter RiskyNameBadgeCostBenchmark
/// ```
///
/// Release, deliberately: a Debug number for pure string-and-dictionary work is not a number worth
/// quoting.
///
/// **This is a measuring instrument, not the regression net.** It prints and asserts nothing, on
/// purpose: the delta it reports (+0.03–0.24 ms against a ~9 ms re-render) is smaller than the
/// spread within either arm, so no threshold over it could separate a real regression from this
/// machine having a busy minute. `RiskyNameBadgeMemoTests` is the net, and it counts evaluations
/// instead of timing them — see its opening note for why that catches what a bar here cannot.
/// Reach for this one when you want to know the current cost, not when you want to be told it
/// changed.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct RiskyNameBadgeCostBenchmark {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["SYNCCLOUD_BADGE_BENCHMARK"] == "1"
    }

    /// One in eight names carries a trailing space, which is roughly what a folder holding a
    /// scanner dump looks like — and far worse than a real provider root, where this Mac's two
    /// largest hold 16 and 4 risky names in ~40,000. Overstating the badged fraction is deliberate:
    /// it prices the expensive case, where the badge actually draws.
    private static func riskyName(_ index: Int, _ base: String) -> String {
        index % 8 == 0 ? base + " " : base
    }

    private struct BadgingDelegate: FileActionDelegate {
        /// nil turns the badge off entirely — the "before" arm, and exactly what a delegate with no
        /// provider context answers.
        let provider: CloudProvider.ProviderType?
        func handleRefresh() {}
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
        func riskyNameReason(forName name: String, isDirectory: Bool) -> String? {
            guard let provider else { return nil }
            return RiskyNameBadgeCache.reason(name: name, isDirectory: isDirectory, provider: provider)
        }
    }

    final class Box: ObservableObject {
        @Published var selection: Set<String> = []
    }

    static let root = "/root"

    /// ~40,000 nodes in the shape the panes actually hold, with names that are DISTINCT strings so
    /// nothing is COW-shared and no name is accidentally free to hash.
    private static func bigTree(side: PaneTree.Side) -> PaneTree {
        var top: [FileNode] = []
        for a in 0..<40 {
            var mid: [FileNode] = []
            for b in 0..<25 {
                let dir = "\(root)/top\(a)/mid\(b)"
                let files = (0..<40).map { c -> FileNode in
                    let name = riskyName(c, "file-\(a)-\(b)-\(c).pdf")
                    return FileNode(id: "\(dir)/\(name)", name: name, isDirectory: false)
                }
                mid.append(FileNode(id: dir, name: "mid\(b)", isDirectory: true, children: files))
            }
            top.append(FileNode(id: "\(root)/top\(a)", name: "top\(a)", isDirectory: true, children: mid))
        }
        return PaneTree(side: side, version: 1, nodes: top)
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let otherTree: PaneTree
        let delegate: FileActionDelegate

        var body: some View {
            FileTreeView(
                tree: tree, otherTree: otherTree, isLoading: false,
                currentPath: RiskyNameBadgeCostBenchmark.root,
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: delegate, diffIndex: .empty)
        }
    }

    private func mount(_ box: Box, delegate: FileActionDelegate, tree: PaneTree, otherTree: PaneTree) -> NSWindow {
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, otherTree: otherTree,
                                                   delegate: delegate))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    private func pump(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }

    private func renderMs(_ window: NSWindow, _ body: () -> Void) -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        body()
        window.layoutIfNeeded()
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
        window.layoutIfNeeded()
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    @Test func priceTheBadgeOnThePaneRenderPath() {
        guard Self.enabled else { return }
        let tree = Self.bigTree(side: .left)
        let otherTree = Self.bigTree(side: .right)

        // One window per arm, both mounted and settled BEFORE any sample is taken, so neither arm
        // is charged for the other's first layout.
        let offBox = Box(), onBox = Box()
        let offWindow = mount(offBox, delegate: BadgingDelegate(provider: nil),
                              tree: tree, otherTree: otherTree)
        let onWindow = mount(onBox, delegate: BadgingDelegate(provider: .oneDrive),
                             tree: tree, otherTree: otherTree)
        pump(offWindow, seconds: 1.0)
        pump(onWindow, seconds: 1.0)

        var off: [Double] = [], on: [Double] = []
        for i in 0..<12 {
            // A selection change re-renders the pane and every visible row of it — the click the
            // user pays for, and the pass the badge rides on.
            let target = "\(Self.root)/top\(i % 40)"
            off.append(renderMs(offWindow) { offBox.selection = [target] })
            on.append(renderMs(onWindow) { onBox.selection = [target] })
        }

        let offMed = median(off), onMed = median(on)
        print(String(format: "BENCH badge off: median %.2f ms, range %.2f–%.2f",
                     offMed, off.min() ?? 0, off.max() ?? 0))
        print(String(format: "BENCH badge on : median %.2f ms, range %.2f–%.2f",
                     onMed, on.min() ?? 0, on.max() ?? 0))
        print(String(format: "BENCH delta    : %+.2f ms (%.1f%%)",
                     onMed - offMed, offMed > 0 ? (onMed - offMed) / offMed * 100 : 0))
    }
}
