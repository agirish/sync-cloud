import AppKit
import Design
import Foundation
import SwiftUI
import Sync

/// One changed pair from the Differences list, opened in the shared file-pair viewer.
///
/// It asks the Duplicates compare's question (what differs between these two files), so it uses
/// the same ``FilePairCompareView`` with a Done-only bar: Differences owns its copy and resolve
/// verbs on the row and in the bulk menu, and a second way to resolve a row would be a second
/// rule table to keep in step.
public struct DifferencePair: Identifiable, Equatable, Sendable {
    let leftPath: String
    let rightPath: String
    /// What the header names the pair. Stored, not derived from a relative path, because the
    /// panes hand over two files a person picked, with no common root and often different names.
    ///
    /// A file name, not a description of the pair, because the header glyph reads its extension
    /// (`FileTypeGlyph.view(name: title, …)`): "Lease.pdf ↔ scan.png" would draw one type over
    /// both. Where the names differ the factories use the left one, and the facts strip's Name row
    /// shows the difference with a ≠ spine.
    let title: String
    /// The line under the title: which panes these two came from.
    let subtitle: String

    public var id: String { [leftPath, rightPath].sorted().joined(separator: "\n") }

    /// Two files in different panes, left pane first. Public because `MacApp`'s row context menu
    /// builds it; a named factory rather than a public initialiser, so the title rule above lives
    /// in one place.
    public static func acrossPanes(leftPath: String, rightPath: String,
                                   leftPaneName: String, rightPaneName: String) -> DifferencePair {
        DifferencePair(leftPath: leftPath, rightPath: rightPath,
                       title: (leftPath as NSString).lastPathComponent,
                       subtitle: "\(leftPaneName) vs \(rightPaneName)")
    }

    /// Two files in the same pane, multi-selected in one tree. "iCloud vs iCloud" would name
    /// nothing, so the subtitle names the pane once. `first` is the row that was right-clicked and
    /// takes the left column, matching where the reader's pointer was.
    public static func withinPane(firstPath: String, secondPath: String,
                                  paneName: String) -> DifferencePair {
        DifferencePair(leftPath: firstPath, rightPath: secondPath,
                       title: (firstPath as NSString).lastPathComponent,
                       subtitle: "Both in \(paneName)")
    }
}

/// Which rows can be compared, and what the pair is.
enum DifferencesPairCompare {

    /// The pair for a row, or nil when there is nothing to compare.
    ///
    /// Both sides must exist, so missing rows are out: an empty pane with a "no longer at its
    /// scanned location" caption is worse than not offering the item. A folder on either side is
    /// out too: this viewer has nothing to render for one, and Compare is the workspace for
    /// folders. Checked by the scan's per-side `leftIsDirectory` / `rightIsDirectory`.
    static func pair(for difference: FileDifference,
                     paneNames: PaneProviderNames) -> DifferencePair? {
        guard difference.type != .missingOnLeft, difference.type != .missingOnRight else {
            return nil
        }
        guard !difference.leftIsDirectory, !difference.rightIsDirectory else { return nil }
        // The same file on two roots, so the relative path's last component is both their names,
        // and the subtitle is the two panes.
        return DifferencePair(leftPath: difference.leftItemPath,
                              rightPath: difference.rightItemPath,
                              title: (difference.relativePath as NSString).lastPathComponent,
                              subtitle: "\(paneNames.left) vs \(paneNames.right)")
    }

    /// The facts the viewer's strip needs, from a fresh stat of both sides, not the row's recorded
    /// sizes: `FileDifference` has no dates, and the strip states what is true now.
    ///
    /// **Off the main actor**, because a stat against an unmounted cloud or SMB volume blocks as
    /// long as the mount takes to answer, and on main that freezes the window.
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
                    // No keeper: the Differences host passes `keeperPath: nil`, and its pane
                    // headers are labels, not pickers.
                    isRecommendedKeeper: false)
            }
            return (copy(leftPath), copy(rightPath))
        }.value
    }
}

/// The Differences host's overlay: scrim, clamp, the shared viewer, and a Done-only bar. An
/// in-window overlay like the Duplicates host's, not a sheet, because macOS clamps a sheet to its
/// window's content width and squeezes it at the 760×560 floor. See ``CompareOverlayMetrics``.
public struct DifferencesPairCompareOverlay: View {

    private let pair: DifferencePair
    private let hue: LiquidGlassHue
    private let onClose: () -> Void

    /// The stat, injected so a test can hold it outstanding and reach the placeholder, which a
    /// real stat of missing paths returns too fast to show. As ``CompareCopiesSheet`` injects
    /// `probe:` and `hash:`. Production passes nothing.
    private let copiesForPair: @Sendable (DifferencePair) async -> (left: DuplicateCopy, right: DuplicateCopy)

    public init(pair: DifferencePair, hue: LiquidGlassHue, onClose: @escaping () -> Void) {
        self.init(pair: pair, hue: hue, onClose: onClose,
                  copies: { await DifferencesPairCompare.copies(for: $0) })
    }

    init(pair: DifferencePair, hue: LiquidGlassHue, onClose: @escaping () -> Void,
         copies: @escaping @Sendable (DifferencePair) async -> (left: DuplicateCopy, right: DuplicateCopy)) {
        self.pair = pair
        self.hue = hue
        self.onClose = onClose
        self.copiesForPair = copies
    }

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// The remembered card size, read here only so the "still statting" placeholder is the size
    /// the card is about to be, and the overlay doesn't jump when the stats land.
    @AppStorage(CompareOverlayMetrics.widthDefaultsKey) private var storedWidth: Double = 0
    @AppStorage(CompareOverlayMetrics.heightDefaultsKey) private var storedHeight: Double = 0

    @State private var copies: (left: DuplicateCopy, right: DuplicateCopy)?
    /// Which pair the outstanding stat is about, the guard the Compare surface's other awaits
    /// carry. `.task(id:)` cancellation is cooperative and the detached stat ignores it, so without
    /// this a pair swapped under an open overlay would draw the old pair's facts under the new
    /// title. The scrim blocks that today, but the host can set `compareDifferencePair` any time.
    @State private var statToken = UUID()
    /// Focus for the placeholder, the only thing mounted while the two stats are in flight. See
    /// ``waitingPlaceholder(size:)``.
    @FocusState private var waitingFocused: Bool

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                OverlayScrim(level: glassLevel)
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
        .task(id: pair.id) {
            let token = UUID()
            statToken = token
            // A fresh pair inherits nothing: the card's facts belong to the pair its title names,
            // so the placeholder shows until this pair's own stat lands.
            copies = nil
            let stat = await copiesForPair(pair)
            guard statToken == token else { return }
            copies = stat
        }
    }

    @ViewBuilder
    private func card(available: CGSize) -> some View {
        let size = CompareOverlayMetrics.size(
            available: available, stored: CGSize(width: storedWidth, height: storedHeight))
        if let copies {
            FilePairCompareView(
                left: copies.left, right: copies.right,
                title: pair.title,
                subtitle: pair.subtitle,
                // No claim: nothing asserts two files at one relative path are copies; the
                // comparison found them different.
                claimHeadline: nil,
                offersVerify: false,
                keeperPath: nil,
                allowsKeeperChoice: false,
                notice: nil,
                // No scan root: the crumbs fall back to a tilde path, since the two files live
                // under different roots.
                scanRoot: nil, providerName: nil, hue: hue,
                availableSize: available,
                onClose: onClose,
                // The Done-only bar names nothing that differs, so the facts it is handed go
                // unread here.
                verdict: { _ in verdictBar })
        } else {
            waitingPlaceholder(size: size)
        }
    }

    /// What is mounted while both sides are being statted. It takes the keyboard so esc closes
    /// the overlay even then: the pair view owns every key but isn't mounted until `copies` lands,
    /// and a dead SMB or cloud volume can block the stat for as long as the reader waits.
    ///
    /// **`.onKeyPress`, never `.cancelAction`:** the whole window is mounted under this overlay,
    /// so a key equivalent would eat bare esc typed anywhere (`BareKeyEquivalentScanTests` bans
    /// it). `isPlainKeystroke`, because `.onKeyPress` receives modified presses too.
    ///
    /// Mounted only in this branch, so there is one esc handler at a time. Focus moves on its own
    /// when the pair view claims it in its `onAppear`.
    @ViewBuilder
    private func waitingPlaceholder(size: CGSize) -> some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: size.width, height: size.height)
            // `.focusEffectDisabled()` for the reason the pair view disables it: the ring is a
            // hard accent rectangle around the whole card, which reads as a stray highlight.
            .focusable()
            .focusEffectDisabled()
            .focused($waitingFocused)
            .onAppear { waitingFocused = true }
            .onKeyPress(keys: [.escape], phases: .down) { press in
                guard press.isPlainKeystroke else { return .ignored }
                onClose()
                return .handled
            }
    }

    /// Done only: the Differences list owns copy, move and ignore for a row in its context and bulk
    /// menus, and a second door here would be a second rule table for one decision.
    private var verdictBar: some View {
        HStack(spacing: 10) {
            Text("Read-only — resolve this row from the list.")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .accentedProminent(hue)
                .controlSize(.regular)
                .shortcutKeycap("↩")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
}
