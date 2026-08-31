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
    let leftPath: String
    let rightPath: String
    /// What the header names the pair.
    ///
    /// **Stored, not derived from a shared relative path, and that is what lets a second host
    /// exist.** It used to read the last component of the difference's `relativePath` — correct
    /// for the Differences list, where the two files are the same file on two roots and share a
    /// name by construction. The panes hand over two files a person picked, which share nothing:
    /// no common root to be relative to, and often not even a name.
    ///
    /// **A file NAME rather than a description of the pair, because the header GLYPH is derived
    /// from it** — `FileTypeGlyph.view(name: title, …)` reads its extension. A title in the shape
    /// "Lease.pdf ↔ scan.png" would draw one of the two types over both, which is a claim about
    /// content rather than a label. Where the two names differ the factories use the left one and
    /// leave the facts strip's Name row to state the difference, which it does with a ≠ spine.
    let title: String
    /// The line under the title: which panes these two came from.
    let subtitle: String

    public var id: String { [leftPath, rightPath].sorted().joined(separator: "\n") }

    /// Two files in DIFFERENT panes, ordered left pane first.
    ///
    /// Public because `MacApp` builds it: the panes' entry point is a row context menu there,
    /// while the memberwise initialiser is internal to this module. A named factory rather than a
    /// public initialiser so the title rule above is enforced in one place instead of trusted to
    /// each caller.
    public static func acrossPanes(leftPath: String, rightPath: String,
                                   leftPaneName: String, rightPaneName: String) -> DifferencePair {
        DifferencePair(leftPath: leftPath, rightPath: rightPath,
                       title: (leftPath as NSString).lastPathComponent,
                       subtitle: "\(leftPaneName) vs \(rightPaneName)")
    }

    /// Two files in the SAME pane — multi-selected in one tree, which the panes allow and the
    /// one-pane-selected invariant has nothing to say about.
    ///
    /// **"iCloud vs iCloud" would name nothing**, which is the note the pane-name fields already
    /// carried; so the subtitle names the one pane once. `first` is the row that was right-clicked
    /// and takes the left column, so the surface matches where the reader's pointer was.
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
        // Unchanged output: the two files are the same file on two roots, so the relative path's
        // last component IS both their names, and the subtitle is the two panes.
        return DifferencePair(leftPath: difference.leftItemPath,
                              rightPath: difference.rightItemPath,
                              title: (difference.relativePath as NSString).lastPathComponent,
                              subtitle: "\(paneNames.left) vs \(paneNames.right)")
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

    /// The stat, injected.
    ///
    /// **A blocked stat cannot be fabricated**, and the placeholder branch only exists while one
    /// is outstanding — so without a seam the test for it would have to win a race against two
    /// stats of paths that do not exist, which return at once. The same reason
    /// ``CompareCopiesSheet`` injects `probe:` and `hash:`, and `BoundedTextRead.read` injects
    /// `isCloudOnly:`. Production passes nothing.
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
    /// the card is about to be. Sized from the default instead, the whole overlay visibly jumped
    /// the moment the two stats landed.
    @AppStorage(CompareOverlayMetrics.widthDefaultsKey) private var storedWidth: Double = 0
    @AppStorage(CompareOverlayMetrics.heightDefaultsKey) private var storedHeight: Double = 0

    @State private var copies: (left: DuplicateCopy, right: DuplicateCopy)?
    /// Focus for the placeholder, which is the only thing mounted while the two stats are in
    /// flight — see ``waitingPlaceholder``.
    @FocusState private var waitingFocused: Bool

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
        .task(id: pair.id) { copies = await copiesForPair(pair) }
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
            waitingPlaceholder(size: size)
        }
    }

    /// What is mounted while both sides are being statted — and it takes the keyboard, because
    /// **esc was dead for exactly as long as that stat took**.
    ///
    /// The pair view owns every key this surface answers, and it is not mounted until `copies`
    /// lands. That looks harmless until you remember why the stat is off the main actor at all: a
    /// dead SMB or unmounted cloud volume can block it indefinitely, and it is precisely then that
    /// the reader wants out. The scrim click still worked, so the surface was not trapping anyone
    /// — but the key that closes every other panel in the app did nothing, on the one surface that
    /// can sit there for a minute.
    ///
    /// **`.onKeyPress`, never `.cancelAction`.** This is an overlay with the whole window mounted
    /// under it, so a key equivalent here would eat bare esc typed anywhere in the window —
    /// `BareKeyEquivalentScanTests` bans it for this module, and the ban is right. `isPlainKeystroke`
    /// for the reason every handler on the pair view carries it: `.onKeyPress` receives modified
    /// presses too.
    ///
    /// Mounted only in this branch, so when the pair view arrives there is exactly ONE esc handler
    /// on the surface rather than two racing to close it. Focus transfers on its own: the pair
    /// view claims it in its own `onAppear`.
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
