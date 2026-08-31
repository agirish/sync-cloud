import AppKit
import Design
import Events
import SwiftUI
import Sync

// MARK: - The payload

/// One file pair, as the Compare Copies surface is opened on it.
///
/// **Copy paths and value snapshots, never the group's UUID.** `DuplicateGroup.id` is minted fresh
/// on every scan — a rescan replaces `duplicateGroups` wholesale — so a payload keyed on it names
/// nothing the moment a scan lands under the open surface: `setKeeper` silently no-ops, and a
/// reveal targets a retired id. `DuplicateCompareContext` set this precedent for the Compare
/// review, by documented design, for the same reason.
///
/// The two sides keep the order they were opened in for the whole life of the surface, even when
/// the keeper is flipped. That is the card's rule too (`choosingKeeper` deliberately leaves the
/// copies where they were): a list that rearranges itself under the click that changed it gives
/// the reader no before and after to compare.
public struct DuplicateComparePair: Identifiable, Equatable {
    let left: DuplicateCopy
    let right: DuplicateCopy
    let matchType: DuplicateMatchType
    /// The group's display name, for the surface's header.
    let groupName: String

    /// The two paths, sorted — so opening the same pair from either side is the same surface and
    /// not a second one sliding in over the first.
    public var id: String { [left.path, right.path].sorted().joined(separator: "\n") }

    /// Opens with the keeper on the left, which is where every other two-copy surface in this app
    /// puts it (the Compare review's banner says "keep left, trash right").
    init(keeper: DuplicateCopy, other: DuplicateCopy, matchType: DuplicateMatchType,
         groupName: String) {
        self.left = keeper
        self.right = other
        self.matchType = matchType
        self.groupName = groupName
    }

    var copies: [DuplicateCopy] { [left, right] }

    func copy(atPath path: String) -> DuplicateCopy? {
        copies.first { $0.path == path }
    }

    /// The copy that is NOT the keeper, given the live keeper path — the one "Trash the other
    /// copy" acts on. nil when the keeper path names neither side, which is what a stale payload
    /// looks like.
    func other(than keeperPath: String) -> DuplicateCopy? {
        guard copies.contains(where: { $0.path == keeperPath }) else { return nil }
        return copies.first { $0.path != keeperPath }
    }
}

// MARK: - Geometry

/// How big the overlay draws inside the space it is given.
///
/// **Not a sheet, and the reason is measured.** macOS clamps a sheet to its host window's content
/// width, the window floor is 760×560, and every existing sheet in this app is a fixed width of
/// 620 or less because of it — so a 1080pt sheet would be silently squeezed exactly when the user
/// is at the floor and has least room to spare. The Settings card and the Help book already solve
/// this the other way: a `GeometryReader` around an overlay that clamps itself against the live
/// window. At the floor this resolves to 712×512 — two ~330pt panes, which is workable; on a large
/// window it opens out to 1080×760 and stops.
///
/// Pure, so the numbers can be checked without rendering anything — and checked at the floor,
/// which is the size nobody develops at.
enum CompareOverlayMetrics {
    static let idealWidth: CGFloat = 1080
    static let idealHeight: CGFloat = 760
    /// The breathing room left around the card, matching the Settings overlay's.
    static let hostMargin: CGFloat = 48
    /// Below this the panes stop being previews. The overlay does not shrink past it — it
    /// overhangs instead, which is visible, where a 40pt-wide preview pane is not.
    static let minimumWidth: CGFloat = 560
    static let minimumHeight: CGFloat = 380

    static func size(available: CGSize) -> CGSize {
        CGSize(width: max(minimumWidth, min(idealWidth, available.width - hostMargin)),
               height: max(minimumHeight, min(idealHeight, available.height - hostMargin)))
    }
}

// MARK: - The surface

/// Two copies of one file, side by side, with the verdict at the bottom.
///
/// Named for what it looks like — a sheet — and presented as an in-window overlay, for the reason
/// ``CompareOverlayMetrics`` gives.
///
/// **The view holds no manager reference.** Every act leaves through a closure, and every fact
/// about the live grouping (who the keeper is, whether a choice is allowed, whether the scan has
/// moved on) arrives as a value the host re-derives at render time by PATH. That is what lets the
/// surface stay honest across a rescan: the host stops finding a live group, passes `isStale`, and
/// the previews stay readable while the verdict goes away.
struct CompareCopiesSheet: View {

    let pair: DuplicateComparePair
    /// The path of the copy currently being kept, read from the LIVE group by the host.
    let keeperPath: String
    /// Whether this group admits a keeper choice at all. Always true for the kinds a FILE group can
    /// be (identical, versions, same-text — overlapping is folders-only), but read off the group
    /// rather than assumed, so the surface and the card cannot drift.
    let allowsKeeperChoice: Bool
    /// Copies that may never be removed — inside a folder another group is keeping.
    let protectedPaths: Set<String>
    /// True when no live group holds both paths any more.
    let isStale: Bool
    let scanRoot: String?
    let providerName: String?
    let accent: Color
    let availableSize: CGSize

    var onChooseKeeper: (String) -> Void
    /// `(copy to trash, keeper)`.
    var onTrash: (DuplicateCopy, DuplicateCopy) -> Void
    var onClose: () -> Void

    /// How a side is classified. A seam for the same reason `ColumnPreviewColumn`'s is: `.cloudOnly`
    /// is otherwise unreachable from a test — the flag is provider-set and cannot be fabricated —
    /// and the placeholder half of this surface renders only in that state.
    var probe: @Sendable (String) async -> ColumnPreviewSource = {
        await ColumnPreviewProbe.read(path: $0).source
    }
    /// How a side is hashed, for "Verify now". Injectable so the three outcomes can be driven.
    var hash: @Sendable (String) async -> FileContentVerifier.HashOutcome = {
        await FileContentVerifier.hashOutcome(filePath: $0, cache: ContentHashCache.shared)
    }

    @State private var sources: [String: ColumnPreviewSource] = [:]
    @State private var verify: ComparePairVerify = .idle
    /// Guards a completion from a verify the user has already superseded — the same token shape
    /// `ReviewCardView.performVerify` uses.
    @State private var verifyToken = UUID()
    @StateObject private var downloads = PaneDownloadWatch()
    @FocusState private var focused: Bool

    private var size: CGSize { CompareOverlayMetrics.size(available: availableSize) }

    private var facts: ComparePairFacts {
        ComparePairFacts.make(left: pair.left, right: pair.right,
                              scanRoot: scanRoot, providerName: providerName)
    }

    private var otherCopy: DuplicateCopy? { pair.other(than: keeperPath) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isStale { staleNotice }
            claimAndFacts
            Divider()
            panes
            Divider()
            verdictBar
        }
        .frame(width: size.width, height: size.height)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        // Plain keys anchored on the surface's focused root. **The `keys:` overload, because it
        // is the one that hands the handler a `KeyPress`** — `.onKeyPress(_:action:)` does not, so
        // a handler written that way cannot tell a bare ← from ⌘←, and `.onKeyPress` is measured
        // to deliver MODIFIED presses to its handlers. `isPlainKeystroke` rather than
        // `modifiers.isEmpty`, per the house rule: Caps Lock alone arrives as a modifier and would
        // kill both keys.
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.isPlainKeystroke else { return .ignored }
            return chooseKeeper(press.key == .leftArrow ? pair.left : pair.right)
        }
        // **⏎ and esc are `.onKeyPress`, NOT key equivalents — and that is a correction to the
        // design this surface was built from.** The plan said to use
        // `.keyboardShortcut(.cancelAction)`/`(.defaultAction)` "the pattern every existing sheet
        // uses". Every existing sheet is a real `.sheet`: window-modal, so its equivalents cannot
        // reach a field behind it. This is an in-window OVERLAY — the Duplicates cards, the panes
        // and their search fields are all still mounted underneath the scrim — and a key
        // equivalent registered here would be a window-level one, eating bare ⏎ and bare esc typed
        // anywhere in the window, on key-repeat. `BareKeyEquivalentScanTests` bans exactly that
        // for every non-sheet file in this module; the ban is right and the plan inherited an
        // assumption from a shape this surface no longer has.
        //
        // `.keypadEnter` beside `.return`: keyCode 76 sends U+0003, not U+000D, so `.return`
        // alone is deaf to one of the two keycaps that say Enter. `isPlainKeystroke` rather than
        // `modifiers.isEmpty` — the keypad's Enter always carries `.numericPad` and `.function`,
        // and Caps Lock rides on every event while it is engaged.
        //
        // **⏎ closes; it never trashes.** The house rule, tested at the Restructure sheet: the
        // safe act keeps the default, and landing a destructive one is a deliberate click.
        .onKeyPress(keys: [.return, .keypadEnter], phases: .down) { press in
            guard press.isPlainKeystroke else { return .ignored }
            onClose()
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare copies of \(pair.groupName)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            FileTypeGlyph.view(name: pair.groupName, isDirectory: false, pointSize: 15)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(pair.groupName)
                    .scaledFont(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindPill)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .accessibilityLabel("Close compare")
            .help(ShortcutHint.tooltip("Close", "esc"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var kindPill: String {
        switch pair.matchType {
        case .identical: return "byte-for-byte"
        case .sameText: return "bytes differ"
        case .versions: return "versions"
        case .overlapping(let f): return "\(Int((f * 100).rounded()))% shared"
        }
    }

    // MARK: Stale notice

    /// A rescan landed under the open surface. The facts on screen are still the ones the previous
    /// scan measured, and saying so is cheaper than tearing the surface down under the user — the
    /// previews are still worth reading, and the verdict is the only thing that must stop.
    private var staleNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("The scan moved on — the facts below are from the last scan, so the verdict is unavailable. Close and compare again.")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    // MARK: Claim + facts strip

    @ViewBuilder
    private var claimAndFacts: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let headline = ComparePairClaim.headline(
                kind: pair.matchType.kind,
                contentUnverified: pair.copies.contains(where: \.contentUnverified)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headline)
                        .scaledFont(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if ComparePairClaim.offersVerify(kind: pair.matchType.kind) {
                        verifyControl
                    }
                }
            }
            if verify != .idle {
                Text(verify.caption)
                    .scaledFont(.system(size: 11.5, weight: verify == .differed ? .semibold : .regular))
                    .foregroundStyle(verify == .differed ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            factsGrid
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var verifyControl: some View {
        HStack(spacing: 6) {
            if verify == .running { ProgressView().controlSize(.small) }
            Button("Verify now") { runVerify() }
                .buttonStyle(.hoverAffordance(.segment, tint: accent))
                .controlSize(.small)
                .disabled(verify == .running)
                .help("Checksum both files to confirm they are still identical right now")
        }
    }

    private var factsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(facts.rows) { row in
                GridRow {
                    Text(row.label)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)
                    factValue(row.left, differs: row.differs)
                    factValue(row.right, differs: row.differs)
                }
            }
        }
    }

    private func factValue(_ text: String, differs: Bool) -> some View {
        Text(text)
            .scaledFont(.system(size: 11.5, weight: differs ? .semibold : .regular,
                                design: .monospaced))
            .foregroundStyle(differs ? Color.primary : Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Panes

    private var panes: some View {
        HStack(spacing: 10) {
            pane(pair.left)
            pane(pair.right)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pane(_ copy: DuplicateCopy) -> some View {
        VStack(spacing: 6) {
            paneHeader(copy)
            previewArea(copy)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                }
        }
    }

    private func paneHeader(_ copy: DuplicateCopy) -> some View {
        let isKeeper = copy.path == keeperPath
        let marker = DuplicateKeeperMarker.style(allowsKeeperChoice: allowsKeeperChoice && !isStale,
                                                 isKeeper: isKeeper)
        return HStack(spacing: 6) {
            Button { chooseKeeper(copy) } label: {
                HStack(spacing: 5) {
                    Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isKeeper ? accent : Color.secondary)
                    Text(isKeeper ? "Keeping this" : "Keep this")
                        .scaledFont(.system(size: 11.5, weight: isKeeper ? .semibold : .regular))
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .disabled(marker == .inert || isKeeper)
            .accessibilityLabel(marker.accessibilityLabel ?? "Copy")
            Spacer(minLength: 6)
            Text(copy.name)
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func previewArea(_ copy: DuplicateCopy) -> some View {
        let source = sources[copy.path]
        ZStack {
            Color.secondary.opacity(0.05)
            switch source {
            case .quickLook:
                // The existing representable, unmodified. Its `dismantleNSView` close is what
                // keeps a Quick Look extension process from leaking per file previewed.
                QuickLookPreview(url: URL(fileURLWithPath: copy.path))
            case .cloudOnly:
                cloudOnlyPlaceholder(copy)
            case .missing:
                placeholder(symbol: "questionmark.folder",
                            caption: "This copy is no longer at its scanned location.",
                            copy: copy, action: nil)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .task(id: probeKey(copy)) {
            sources[copy.path] = await probe(copy.path)
        }
    }

    /// Re-probes when the path changes AND when a download this surface is watching concludes —
    /// the latch is what turns "cloud-only" into a real preview without a second poller.
    private func probeKey(_ copy: DuplicateCopy) -> String {
        "\(copy.path)|\(downloads.request(forPath: copy.path)?.requestID.uuidString ?? "-")"
    }

    @ViewBuilder
    private func cloudOnlyPlaceholder(_ copy: DuplicateCopy) -> some View {
        if downloads.request(forPath: copy.path) != nil {
            placeholder(symbol: "icloud.and.arrow.down",
                        caption: "Downloading…", copy: copy, action: nil)
        } else {
            placeholder(symbol: "icloud",
                        caption: "Not downloaded — nothing to preview, and nothing to compare.",
                        copy: copy, action: .download)
        }
    }

    private enum PlaceholderAction { case download }

    @ViewBuilder
    private func placeholder(symbol: String, caption: String, copy: DuplicateCopy,
                             action: PlaceholderAction?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(caption)
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if action == .download {
                Button("Download") { requestDownload(copy) }
                    .buttonStyle(.hoverAffordance(.segment, tint: accent))
                    .controlSize(.small)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)])
            }
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .controlSize(.small)
        }
        .padding(16)
    }

    // MARK: Verdict

    private var verdictBar: some View {
        HStack(spacing: 10) {
            Text(verdictSummary)
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            trashButton
            // **⏎ AND esc both mean Done** — see the `.onKeyPress` handlers on the root, which is
            // where both keys live. An earlier draft of this surface put ⌘⏎ on the trash button.
            Button("Done", action: onClose)
                .controlSize(.regular)
                .shortcutKeycap("⏎")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var verdictSummary: String {
        if isStale { return "Rescan to act on this pair." }
        return ComparePairFacts.summary(differing: facts.differingFields)
    }

    @ViewBuilder
    private var trashButton: some View {
        let other = otherCopy
        let reason = other.flatMap {
            DuplicateComparePrompt.disabledReason(copyIsProtected: protectedPaths.contains($0.path),
                                                  copyName: $0.name)
        }
        Button(role: .destructive) {
            if let other, let keeper = pair.copy(atPath: keeperPath) { onTrash(other, keeper) }
        } label: {
            Label(trashTitle, systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isStale || other == nil || reason != nil)
        .help(reason ?? "Move the other copy to the Trash")
    }

    private var trashTitle: String {
        switch pair.matchType {
        case .versions: return "Trash the older copy"
        default: return "Trash the other copy"
        }
    }

    // MARK: Actions

    /// The one keeper flip, for the pane button and for ←/→ alike. Returns `.ignored` when there
    /// is nothing to flip, so an arrow key over a stale surface falls through to whatever else
    /// might want it rather than being swallowed.
    @discardableResult
    private func chooseKeeper(_ copy: DuplicateCopy) -> KeyPress.Result {
        guard !isStale, allowsKeeperChoice, copy.path != keeperPath else { return .ignored }
        onChooseKeeper(copy.path)
        return .handled
    }

    private func requestDownload(_ copy: DuplicateCopy) {
        do {
            try MaterializationStatus.download(atPath: copy.path)
            // This surface owns its own watch, so no pane latches a download it did not start —
            // the double-watch the pane-scoped token exists to prevent, reached from a new door.
            downloads.begin(CloudDownloadRequest(path: copy.path, paneToken: .compareCopies))
        } catch {
            // Only iCloud exposes a consumer download API; for every other File Provider this
            // throws, and the honest fallback is Finder, which can reach the provider's extension.
            Logger.shared.warning("[compare] no download API for \(copy.path): \(error.localizedDescription) — revealing in Finder")
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)])
        }
    }

    private func runVerify() {
        guard verify != .running else { return }
        verify = .running
        let token = UUID()
        verifyToken = token
        let leftPath = pair.left.path
        let rightPath = pair.right.path
        let hash = self.hash
        Task { @MainActor in
            async let l = hash(leftPath)
            async let r = hash(rightPath)
            let outcome = ComparePairVerify.outcome(left: await l, right: await r)
            // A completion from a verify the user has already superseded describes a question
            // nobody is asking any more.
            guard verifyToken == token else { return }
            verify = outcome
        }
    }
}

// MARK: - The host-side overlay

/// The Compare Copies surface as the window presents it: scrim, clamp, card treatment — and the
/// one place that re-derives the LIVE grouping the sheet renders against.
///
/// **Public, and the only public thing here**, so `ContentView` mounts one view and knows nothing
/// about pair verdicts, keeper rules or stale scans. That knowledge belongs beside the sheet, and
/// the sheet itself stays free of any manager reference — every act it performs leaves through a
/// closure this wrapper supplies.
///
/// **Everything is re-derived on every render, by path.** `DuplicateGroup.id` does not survive a
/// rescan, so the keeper, the keeper-choice rule, the protected set and "has the scan moved on"
/// are read out of `duplicateGroups` at draw time — which means a rescan landing under the open
/// surface re-validates it for free, with no observer to wire and none to forget.
public struct CompareCopiesOverlay: View {

    @ObservedObject private var syncManager: FileSyncManager
    private let pair: DuplicateComparePair
    private let scanRoot: String?
    private let providerName: String?
    private let onClose: () -> Void

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    public init(syncManager: FileSyncManager, pair: DuplicateComparePair,
                scanRoot: String?, providerName: String?,
                onClose: @escaping () -> Void) {
        self.syncManager = syncManager
        self.pair = pair
        self.scanRoot = scanRoot
        self.providerName = providerName
        self.onClose = onClose
    }

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    /// The group holding BOTH paths right now, or nil once the scan has moved on.
    private var liveGroup: DuplicateGroup? {
        syncManager.liveGroup(holding: pair.right.path, and: pair.left.path)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                sheet(available: proxy.size)
                    // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                    .contentShape(Rectangle())
                    .contentSurface(hue: glassHue, tint: surfaceTint)
                    .groundedGlassCard(level: glassLevel)
                    .overlayPanelShadow()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }

    private func sheet(available: CGSize) -> some View {
        let group = liveGroup
        // The keeper as the LIVE group names it. Falling back to the payload's left side is what
        // keeps a stale surface readable rather than blank — the verdict is disabled anyway.
        let keeperPath = group.flatMap { g in
            pair.copies.first { $0.path == g.keeper.path }?.path
        } ?? pair.left.path
        return CompareCopiesSheet(
            pair: pair,
            keeperPath: keeperPath,
            allowsKeeperChoice: group?.allowsKeeperChoice ?? false,
            protectedPaths: Set((group?.copies ?? []).filter(\.isProtectedFromRemoval).map(\.path)),
            isStale: group == nil,
            scanRoot: scanRoot,
            providerName: providerName,
            accent: glassHue.accentColor,
            availableSize: available,
            onChooseKeeper: { path in
                // Re-looked-up at CLICK time, not captured: `setKeeper` takes a group id, and the
                // id this surface opened over may already have been replaced by a rescan — in
                // which case it silently no-ops. Reading the live group here means the flip either
                // lands on the current group or does not happen at all.
                guard let live = syncManager.liveGroup(holding: pair.right.path,
                                                       and: pair.left.path) else { return }
                syncManager.setKeeper(for: live.id, to: path)
            },
            onTrash: { copy, keeper in trash(copy, keeper: keeper) },
            onClose: onClose)
    }

    /// The destructive act: confirm in the app's own destructive dialog, then hand the pair to the
    /// engine, which re-verifies both ends and gates the removal.
    ///
    /// The confirmation is a plain deliberate click — never `⏎`, which belongs to Done. Its wording
    /// comes from ``DuplicateComparePrompt`` rather than being composed here, for the reason that
    /// type exists: inline destructive wording in a view is untestable, and this app has already
    /// shipped a dialog that called an unproven copy "redundant" at the point of no return.
    private func trash(_ copy: DuplicateCopy, keeper: DuplicateCopy) {
        let reclaim = FileSyncManager.formatBytes(copy.size)
        let keeperLocation = DuplicateGroupCard
            .crumbs(of: keeper.path, scanRoot: scanRoot, providerName: providerName)
            .dropLast().joined(separator: " › ")
        guard NativeAlerts.confirmDestructive(
            messageText: DuplicateComparePrompt.messageText(copyName: copy.name),
            informativeText: DuplicateComparePrompt.informativeText(
                kind: pair.matchType.kind, keeperName: keeper.name,
                keeperLocation: keeperLocation, reclaimText: reclaim),
            confirmTitle: DuplicateComparePrompt.confirmTitle) else {
            Logger.shared.info("User declined trashing the compared copy \(copy.path)")
            return
        }
        Task { @MainActor in
            // The surface closes only on a removal that actually happened. A refusal — a drifted
            // copy, a keeper that moved, a scan that landed underneath — posts its banner and
            // leaves the pair up, which is where the user can see what it said and try again.
            if await syncManager.resolveDuplicateCopy(copy, keeper: keeper) { onClose() }
        }
    }
}
