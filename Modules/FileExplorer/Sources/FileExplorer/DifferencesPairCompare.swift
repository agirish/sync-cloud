import AppKit
import Design
import Foundation
import SwiftUI
import Sync

/// One changed pair from the Differences list, opened in the shared file-pair viewer.
///
/// **This is ROADMAP §11, and it is one build rather than two.** The roadmap has been asking for
/// "a read-only side-by-side or unified diff for a selected pair in the Differences list"; that is
/// the same question the Duplicates compare answers — what is different between these two files —
/// so it is the same component, ``FilePairCompareView``, with a different bottom bar. Differences
/// already owns its copy/resolve verbs on the row and in the bulk menu, so the bar here is Done
/// only: a viewer that grew a second way to resolve a row would be a second rule table to keep in
/// step with the first.
public struct DifferencePair: Identifiable, Equatable, Sendable {
    let relativePath: String
    let leftPath: String
    let rightPath: String
    /// The panes' display names, already disambiguated by `PaneProviderNames` when both show the
    /// same provider — this is the subtitle, and "iCloud vs iCloud" would name nothing.
    let leftPaneName: String
    let rightPaneName: String

    public var id: String { [leftPath, rightPath].sorted().joined(separator: "\n") }

    var title: String { (relativePath as NSString).lastPathComponent }
    var subtitle: String { "\(leftPaneName) vs \(rightPaneName)" }
}

/// Which rows can be compared, and what the pair is.
enum DifferencesPairCompare {

    /// The pair for a row, or nil when there is nothing to compare.
    ///
    /// **Both sides must exist**, which rules out `.missingOnLeft` and `.missingOnRight`
    /// immediately: a viewer given a path that is not there shows an empty pane and a "no longer
    /// at its scanned location" caption, which is a worse answer than not offering the item.
    ///
    /// **And folders are out.** A folder pair has nothing this viewer can render — Quick Look
    /// draws an icon, there is no page to raster and no text to diff — and Compare already has a
    /// whole workspace for two folders. `enclosedItemCount` is the scan's own folder marker: it is
    /// recorded only for a folder (its contents sync with it rather than being listed as separate
    /// rows), so a non-nil count is the one fact the row carries that says "directory".
    static func pair(for difference: FileDifference,
                     paneNames: PaneProviderNames) -> DifferencePair? {
        guard difference.type != .missingOnLeft, difference.type != .missingOnRight else {
            return nil
        }
        guard difference.enclosedItemCount == nil else { return nil }
        return DifferencePair(relativePath: difference.relativePath,
                              leftPath: difference.leftItemPath,
                              rightPath: difference.rightItemPath,
                              leftPaneName: paneNames.left,
                              rightPaneName: paneNames.right)
    }

    /// The facts the viewer's strip needs, from a fresh stat of both sides.
    ///
    /// **A stat, not the row's recorded sizes.** `FileDifference` carries the sizes the comparison
    /// measured and no dates at all, and the strip's whole job is to state what is true now — a
    /// date row reading "—" on both sides would be the surface admitting it did not look. Off the
    /// main actor, because a stat against an unmounted cloud or SMB volume blocks for as long as
    /// the mount takes to answer, and on the main actor that is the window.
    static func copies(for pair: DifferencePair) async -> (left: DuplicateCopy, right: DuplicateCopy) {
        let leftPath = pair.leftPath, rightPath = pair.rightPath
        return await Task.detached(priority: .userInitiated) {
            func copy(_ path: String) -> DuplicateCopy {
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return DuplicateCopy(
                    id: path,
                    name: (path as NSString).lastPathComponent,
                    isDirectory: false,
                    size: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                    itemCount: 1,
                    modificationDate: attributes?[.modificationDate] as? Date,
                    uniqueItemCount: 0,
                    depth: 0,
                    // No keeper here at all — the Differences host passes `keeperPath: nil` and
                    // its pane headers are labels rather than pickers.
                    isRecommendedKeeper: false)
            }
            return (copy(leftPath), copy(rightPath))
        }.value
    }
}

/// The Differences host's overlay: scrim, clamp, the shared viewer, and a Done-only bar.
///
/// The same in-window overlay the Duplicates host uses, and for the same measured reason — macOS
/// clamps a sheet to its window's content width, so a wide sheet is silently squeezed exactly at
/// the 760×560 floor. See ``CompareOverlayMetrics``.
public struct DifferencesPairCompareOverlay: View {

    private let pair: DifferencePair
    private let hue: LiquidGlassHue
    private let onClose: () -> Void

    public init(pair: DifferencePair, hue: LiquidGlassHue, onClose: @escaping () -> Void) {
        self.pair = pair
        self.hue = hue
        self.onClose = onClose
    }

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    @State private var copies: (left: DuplicateCopy, right: DuplicateCopy)?

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                card(available: proxy.size)
                    .contentShape(Rectangle())
                    .contentSurface(hue: hue, tint: surfaceTint)
                    .groundedGlassCard(level: glassLevel)
                    .overlayPanelShadow()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
        .task(id: pair.id) { copies = await DifferencesPairCompare.copies(for: pair) }
    }

    @ViewBuilder
    private func card(available: CGSize) -> some View {
        let size = CompareOverlayMetrics.size(available: available)
        if let copies {
            FilePairCompareView(
                left: copies.left, right: copies.right,
                title: pair.title,
                subtitle: pair.subtitle,
                // **No claim, deliberately.** Two files at one relative path on two roots are not
                // asserted to be copies of each other by anything — the comparison found them
                // different, which is why the row exists. A headline here would be inventing one.
                claimHeadline: nil,
                offersVerify: false,
                keeperPath: nil,
                allowsKeeperChoice: false,
                notice: nil,
                // No scan root: the crumbs fall back to a tilde path, which is the honest form for
                // two files that live under different roots and share no trunk to be relative to.
                scanRoot: nil, providerName: nil, hue: hue,
                availableSize: available,
                onClose: onClose,
                verdict: { verdictBar })
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: size.width, height: size.height)
        }
    }

    /// **Done only.** The Differences list already owns copy, move and ignore for a row, in its own
    /// context menu and its bulk menu; putting a second door on them here would be a second rule
    /// table for one decision. The slot exists, so a later release can host them without moving
    /// anything else.
    private var verdictBar: some View {
        HStack(spacing: 10) {
            Text("Read-only — resolve this row from the list.")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(hue.accentColor)
                .controlSize(.regular)
                .shortcutKeycap("⏎")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
}
