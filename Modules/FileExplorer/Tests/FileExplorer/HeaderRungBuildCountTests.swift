import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// How many header rows the Compare header builds to lay itself out. `ViewThatFits` builds each
/// child in turn until one fits, so searching the six rungs pays for a whole toolbar per rung down
/// to the one chosen; the computed rung (`HeaderLadder`) builds the rung it chose, and the narrowest
/// one behind it only when the layout engine's veto has to be asked. Nothing else fails if the
/// search comes back.
///
/// Counted, not timed. The host's accessory is a probe that counts its body evaluations, and every
/// header row draws the accessory once, so the mounted header's count over a lone row's count is
/// how many rows it built. Measured: one or two at these widths; with the six-child search put
/// back in `hedged`, three, four and six. The widths are where the search reaches past its first
/// rung: in a pane wide enough for `.full` it builds one row too, and nothing can tell them apart.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable)
struct HeaderRungBuildCountTests {

    private final class Counter { var bodies = 0 }

    private struct Probe: View {
        let counter: Counter
        var body: some View {
            counter.bodies += 1
            return Color.clear.frame(width: 12, height: 12)
        }
    }

    private func view(counting counter: Counter) -> DifferencesView {
        let rows = (0..<40).map { index in
            FileDifference(
                relativePath: "Documents/file-\(index).txt",
                leftItemPath: "/left/file-\(index).txt", rightItemPath: "/right/file-\(index).txt",
                type: index.isMultiple(of: 3) ? .differentDates : .missingOnRight,
                action: index.isMultiple(of: 3) ? .copyToLeft : .copyToRight,
                description: "x", leftFileSize: 1_024, rightFileSize: 1_024)
        }
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = true
        return DifferencesView(
            syncManager: manager, reviewStore: ReviewSessionStore(),
            paneNames: PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive"),
            isCollapsed: .constant(false),
            accessory: AnyView(Probe(counter: counter)), accessoryWidth: 12)
    }

    /// Mounts `content` at `width`, lets it settle, and returns how many probe bodies it built.
    private func bodies(_ content: some View, counter: Counter, width: CGFloat,
                        defaults: UserDefaults) async -> Int {
        let host = NSHostingView(rootView: AnyView(content.defaultAppStorage(defaults)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        // Settled, not merely built: the count must not rise between two passes.
        var last = -1
        _ = await LayoutPumpWait.pump(host, upTo: 5) {
            defer { last = counter.bodies }
            return counter.bodies > 0 && counter.bodies == last
        }
        return counter.bodies
    }

    @Test(arguments: [CGFloat(900), 700, 500])
    func theHeaderBuildsItsRungAndTheHedgeOnly(width: CGFloat) async throws {
        let rowCounter = Counter()
        let row = view(counting: rowCounter)
        let facts = HeaderLadder.Facts(
            differencesCount: 40, detail: nil, detailIsCapsuled: false,
            chevronSymbol: nil, itemCountsText: nil, sectionCount: 1, filterName: "All",
            isSelectionScoped: false, targetCount: 40, verifiableCount: 0,
            copyToLeftCount: 14, copyToRightCount: 26, reverseIsMajority: false,
            leftName: "OneDrive — Personal", rightName: "iCloud Drive", isMove: false,
            showsCollapseToggle: true)
        let lone = await bodies(
            row.standardHeaderRow(.full, facts: facts, dressing: .init(
                semantic: .onAccent(fill: .blue, label: .white), detailStyle: nil, detail: nil,
                spokenDetail: nil, help: nil),
                targets: DifferenceActionTargets(filtered: [], selection: []), sorted: [], sections: []),
            counter: rowCounter, width: width, defaults: ScratchDefaults("HeaderRungBuildCount-row"))
        try #require(lone > 0, "the probe never ran in a lone row — the count below would be vacuous")

        let headerCounter = Counter()
        let header = await bodies(view(counting: headerCounter), counter: headerCounter, width: width,
                                  defaults: ScratchDefaults("HeaderRungBuildCount-header"))
        #expect(header > 0, "the mounted header never drew its accessory — the bound below is vacuous")
        #expect(header < 3 * lone,
                "the header built \(header) probe bodies against \(lone) for one row — it is building more rows than the computed rung and its hedge")
    }
}
