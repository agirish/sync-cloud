import AppKit
import Design
import Events
import SwiftUI
import Sync

// MARK: - The payload

/// One file pair, as the Compare Copies surface is opened on it.
///
/// Copy paths and value snapshots, never the group's UUID: `DuplicateGroup.id` is minted fresh on
/// every scan, so a payload keyed on it would name nothing once a scan lands under the open surface
/// (`setKeeper` would silently no-op, a reveal would target a retired id). `DuplicateCompareContext`
/// follows the same rule.
///
/// The two sides keep their opening order for the life of the surface, even when the keeper is
/// flipped, as on the card (`choosingKeeper` leaves the copies where they were): a list that
/// rearranges itself under the click gives the reader no before and after.
public struct DuplicateComparePair: Identifiable, Equatable, Sendable {
    let left: DuplicateCopy
    let right: DuplicateCopy
    let matchType: DuplicateMatchType
    /// The group's display name, for the surface's header.
    let groupName: String

    /// The two paths, sorted, so opening the same pair from either side is the same surface, not a
    /// second one sliding in over the first.
    public var id: String { [left.path, right.path].sorted().joined(separator: "\n") }

    /// Opens with the keeper on the left, where every other two-copy surface in this app puts it
    /// (the Compare review's banner says "keep left, trash right").
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

    /// The copy that is not the keeper, given the live keeper path: the one "Trash the other copy"
    /// acts on. nil when the keeper path names neither side, which is what a stale payload looks
    /// like.
    func other(than keeperPath: String) -> DuplicateCopy? {
        guard copies.contains(where: { $0.path == keeperPath }) else { return nil }
        return copies.first { $0.path != keeperPath }
    }
}

// MARK: - Geometry

/// How big the overlay draws inside the space it is given.
///
/// Not a sheet: macOS clamps a sheet to its host window's content width, and the window floor is
/// 760×560, so a 1080pt sheet would be squeezed exactly when the user has least room. Like the
/// Settings card and the Help book, it is an overlay in a `GeometryReader` that clamps itself to
/// the live window: 762×512 at the floor (two ~355pt panes), up to 1080×760 on a large window.
///
/// Pure, so the numbers can be checked without rendering, and at the floor, the size nobody
/// develops at.
enum CompareOverlayMetrics {
    static let idealWidth: CGFloat = 1080
    static let idealHeight: CGFloat = 760
    /// The breathing room left around the card, matching the Settings overlay's.
    static let hostMargin: CGFloat = 48
    /// Below this the panes stop being previews. The overlay doesn't shrink past it; it overhangs
    /// instead, which is visible, where a 40pt-wide preview pane isn't.
    static let minimumWidth: CGFloat = 560
    static let minimumHeight: CGFloat = 380

    static var minimum: CGSize { CGSize(width: minimumWidth, height: minimumHeight) }

    /// The remembered size. Two keys rather than one archived `CGSize`, as for the Help card: a
    /// width that survives a height's decoding failure beats losing both, and `@AppStorage` reads
    /// `Double` natively. `0` means "never resized", and the default is what the window can give.
    static let widthDefaultsKey = "compareOverlayWidth"
    static let heightDefaultsKey = "compareOverlayHeight"

    /// What the card opens at on a window of `available`, before any remembered size.
    static func size(available: CGSize) -> CGSize {
        CGSize(width: max(minimumWidth, min(idealWidth, available.width - hostMargin)),
               height: max(minimumHeight, min(idealHeight, available.height - hostMargin)))
    }

    /// The size to draw at: the remembered one when there is one, always held to the floor and to
    /// what the window can show.
    ///
    /// A stored size is clamped on every render, not only when written. The window can shrink
    /// between sessions or displays, and a card that trusted its stored size would open wider than
    /// its window, with the verdict bar and the resize grip off screen.
    static func size(available: CGSize, stored: CGSize?) -> CGSize {
        guard let stored, stored.width > 0, stored.height > 0 else { return size(available: available) }
        return ResizableCardSize.clamped(stored, minimum: minimum, within: available)
    }
}

// MARK: - The surface

/// Two copies of one file, side by side, with the verdict at the bottom. Named for what it looks
/// like, a sheet, but presented as an in-window overlay (see ``CompareOverlayMetrics``).
///
/// The view holds no manager reference. Every act leaves through a closure, and every fact about
/// the live grouping (the keeper, whether a choice is allowed, whether the scan moved on) arrives
/// as a value the host re-derives by path at render time. So across a rescan the host stops finding
/// a live group, passes a nil keeper and a notice, and the previews stay readable while the verdict
/// goes away.
struct FilePairCompareView<Verdict: View>: View {

    let left: DuplicateCopy
    let right: DuplicateCopy
    /// What the surface is comparing: a duplicate group's name, or a relative path.
    let title: String
    /// The line under it: a match kind, or which two roots the pair came from.
    let subtitle: String
    /// The claim the pair's origin makes about its content, or nil where it makes none. The
    /// Differences host makes none: two files at one relative path on two roots aren't asserted to
    /// be anything.
    let claimHeadline: String?
    /// Whether "Verify now" is offered: only where a byte-identical claim exists to re-check.
    let offersVerify: Bool
    /// The path of the copy being kept, or nil where there is no keeper concept. The Differences
    /// host passes nil, and its pane headers are labels rather than pickers.
    let keeperPath: String?
    /// Whether the keeper may be changed. Read off the live group rather than assumed, so the
    /// surface and the card can't drift.
    let allowsKeeperChoice: Bool
    /// A line the host wants above the facts: the duplicates host's "the scan moved on" notice.
    let notice: String?
    let scanRoot: String?
    let providerName: String?
    /// The window's hue, not a resolved `Color`: `.accentedSegments` on the mode picker needs the
    /// hue itself (a literal is what that modifier prevents), so the surface carries the hue and
    /// resolves the accent from it rather than carrying both and letting them disagree.
    let hue: LiquidGlassHue
    let availableSize: CGSize

    var onChooseKeeper: (String) -> Void = { _ in }
    var onClose: () -> Void

    /// How a side is classified. A seam, as `ColumnPreviewColumn`'s is: `.cloudOnly` is
    /// provider-set and can't be fabricated in a test, and the placeholder half of this surface
    /// renders only in that state.
    var probe: @Sendable (String) async -> ColumnPreviewSource = {
        await ColumnPreviewProbe.read(path: $0).source
    }
    /// How a side is hashed, for "Verify now". Injectable so the three outcomes can be driven.
    var hash: @Sendable (String) async -> FileContentVerifier.HashOutcome = {
        await FileContentVerifier.hashOutcome(filePath: $0, cache: ContentHashCache.shared)
    }
    /// The mode to open in. nil, as every production caller passes, means side by side.
    ///
    /// A seam for one property: a pixel mode entered before the sides are classified must still get
    /// them classified, and a test can't post a key into a `@State` mode.
    var initialMode: ComparePairMode?

    /// The only part the two hosts don't share. The facts, panes, modes and strip are one
    /// component; only the bottom bar knows why you are looking: Duplicates offers a keeper and a
    /// trash, Differences offers Done.
    ///
    /// Given the facts the viewer built rather than deriving them again: the bar's line and the
    /// strip above it must name the same rows, and only this view has the page counts.
    @ViewBuilder var verdict: (ComparePairFacts) -> Verdict

    /// The pair's viewer kind. Both sides must agree, or the pair is `.other`: a versions group
    /// can hold `Report.pdf` beside `Report.docx`, and a PDF viewer given a Word document shows a
    /// blank pane rather than saying it can't page it.
    ///
    /// Stored, resolved once in `init`: it is read many times per render, each read is two
    /// `PairContentKind.classify` calls (a `UTType` lookup and possibly a conformance walk), and the
    /// body re-runs on every manager publish and every swipe-divider pointer event. It depends only
    /// on two `let` paths.
    private let kind: PairContentKind

    /// Spelled out rather than left to the memberwise initializer, only so ``kind`` can be resolved
    /// once. Parameters, order and defaults match the memberwise one.
    init(left: DuplicateCopy, right: DuplicateCopy, title: String, subtitle: String,
         claimHeadline: String?, offersVerify: Bool, keeperPath: String?,
         allowsKeeperChoice: Bool, notice: String?, scanRoot: String?, providerName: String?,
         hue: LiquidGlassHue, availableSize: CGSize,
         onChooseKeeper: @escaping (String) -> Void = { _ in },
         onClose: @escaping () -> Void,
         probe: @escaping @Sendable (String) async -> ColumnPreviewSource = {
             await ColumnPreviewProbe.read(path: $0).source
         },
         hash: @escaping @Sendable (String) async -> FileContentVerifier.HashOutcome = {
             await FileContentVerifier.hashOutcome(filePath: $0, cache: ContentHashCache.shared)
         },
         initialMode: ComparePairMode? = nil,
         @ViewBuilder verdict: @escaping (ComparePairFacts) -> Verdict) {
        self.left = left
        self.right = right
        self.title = title
        self.subtitle = subtitle
        self.claimHeadline = claimHeadline
        self.offersVerify = offersVerify
        self.keeperPath = keeperPath
        self.allowsKeeperChoice = allowsKeeperChoice
        self.notice = notice
        self.scanRoot = scanRoot
        self.providerName = providerName
        self.hue = hue
        self.availableSize = availableSize
        self.onChooseKeeper = onChooseKeeper
        self.onClose = onClose
        self.probe = probe
        self.hash = hash
        self.initialMode = initialMode
        self.verdict = verdict
        let leftKind = PairContentKind.classify(path: left.path)
        self.kind = leftKind == PairContentKind.classify(path: right.path) ? leftKind : .other
    }

    @State private var sources: [String: ColumnPreviewSource] = [:]
    @State private var verify: ComparePairVerify = .idle
    @State private var mode: ComparePairMode = .sideBySide
    @State private var page = 0
    /// nil until the page counts have been asked for.
    ///
    /// "Not asked yet" and "opens to nothing" are different. If they were one state, a PDF pair
    /// would fall through to the Quick Look panes while the count was in flight and swap to the
    /// typed viewer when it landed: a visible flicker, and a Quick Look extension spun up for
    /// nothing.
    @State private var pairing: PagePairing?
    @State private var rasters: (left: CGImage?, right: CGImage?) = (nil, nil)
    /// The difference raster and the regions it found, held as one value.
    ///
    /// Two `@State`s would be two lifetimes for one computation. Several places clear or set this,
    /// and a count that outlived its canvas would caption a page the reader is no longer looking
    /// at; the struct makes that unwriteable.
    private struct PageComparison: Equatable {
        var image: CGImage?
        /// Changed regions in the difference raster's pixel coordinates. See ``BitmapDiff``.
        var regions: [CGRect] = []
    }
    @State private var pageComparison = PageComparison()
    /// Guards a page search still walking when the pair or the page moves under it: the raster
    /// path's token, for the same race.
    @State private var pageSearchToken = UUID()
    /// Whether a ↑/↓ search is walking pages right now, so the strip can say so rather than look
    /// like a key that did nothing on a document whose next difference is far away.
    @State private var pageSearching = false
    /// The ↑/↓ page walk in flight, held so it can be cancelled rather than only ignored.
    ///
    /// The token alone leaves the work running: the walk renders up to
    /// ``PageDifferenceStepper/renderBudget`` page pairs, two PDFKit serial-lane turns each, and a
    /// superseded search would go on opening documents on the lane a running scan shares. The token
    /// stops a stale verdict landing; this stops the work.
    @State private var pageSearchTask: Task<Void, Never>?
    @State private var pageStates: [Int: PageDiffState] = [:]
    @State private var swipeFraction: Double = 0.5
    @State private var onionOpacity: Double = 0.5
    /// ⌥ held: the two viewers stop mirroring each other so one pane can be moved on its own.
    @State private var optionHeld = false
    /// The PDF panes' zoom, held here rather than in the viewer, because the viewer doesn't survive
    /// a mode switch.
    ///
    /// `panes` switches on the mode, so `2`–`4` unmount `PDFPairView` and `1` builds a fresh one,
    /// with `autoScales` back to fit. The page already survives that round trip by living here; the
    /// zoom is the other half of where the reader was, and losing it on every `1`–`4` press would
    /// tax the workflow the modes exist for.
    ///
    /// nil until the reader zooms: `autoScales` owns the fit until then, and a never-zoomed surface
    /// must not take that from it.
    @State private var pdfZoom: CGFloat?
    /// Guards a raster that arrives after the user has paged on: the same token shape the verify
    /// uses, for the same reason.
    @State private var rasterToken = UUID()
    /// Which pair, page and side the rasters in hand are of, or nil when there are none (see
    /// ``decodeKey``). What lets a mode change reuse a decode instead of redoing it.
    @State private var heldRasterKey: String?
    /// Which decode ``pageComparison`` was made from, or nil when nothing has been compared.
    @State private var heldComparisonKey: String?
    /// Whether that comparison had the de-skew applied. See ``PageComparisonReuse``, which stops a
    /// mode press replacing an aligned verdict with a weaker one.
    @State private var heldComparisonAligned = false
    /// Whether the current page's rasters are still coming or never will. A pane with no image and
    /// no answer here would spin for the life of the surface (see ``PairRenderOutcome``).
    @State private var renderOutcome: PairRenderOutcome = .rendering
    /// The alignment applied to the page on screen, or nil where none was.
    ///
    /// Per page and per render, cleared with the rasters, because it describes one comparison: a
    /// value surviving into the next page would caption it with the previous one's skew.
    @State private var pageRegistration: PageRegistration?
    @State private var textDiff: TextPairDiff?
    @State private var textNotes: [String] = []
    /// The pair the held diff is about, or nil when there is none.
    ///
    /// What lets the diff survive a mode toggle. Keyed on the mode too, every `1`→`2` press would
    /// re-read both files (up to 8 MB), re-split them and re-run the walk. A pair never switched to
    /// Diff should cost nothing, but that laziness needs no eviction; this memo separates the two.
    @State private var textDiffPairKey: String?
    /// The pass in flight, held so it can be cancelled by a pair change and by the surface closing.
    /// `.task(id:)` cancels the awaiting task, which a `Task.detached` inside it never hears; the
    /// handle is the only way to reach the walk, which checks `Task.isCancelled` on every step of
    /// its outer loop.
    @State private var textDiffTask: Task<TextDiffResult, Never>?
    /// Guards a diff that lands after the pair moved on: the raster path's token, for a race the
    /// text path is more exposed to. Two detached Myers passes have no ordering, so a slow pair's
    /// diff can resume after a fast pair's has been drawn.
    @State private var textDiffToken = UUID()
    /// Which change ↑/↓ last stepped to, or nil while nothing has been stepped to yet.
    ///
    /// Optional rather than 0, because "the first change" and "no change chosen" are different
    /// states: starting at 0, the first ↓ would skip to the second change, and the counter would
    /// read "1 of N" about a region nothing had scrolled to.
    @State private var focusedRegion: Int?
    /// Guards a completion from a verify the user has already superseded: the same token shape
    /// `ReviewCardView.performVerify` uses.
    @State private var verifyToken = UUID()
    /// The running Verify Now, so closing the surface or changing the pair stops its reads. The
    /// token only stops a stale verdict landing; with no size cap on the hash, the read could go on
    /// for gigabytes after nothing was waiting for it.
    @State private var verifyTask: Task<Void, Never>?
    @StateObject private var downloads = PaneDownloadWatch()
    @FocusState private var focused: Bool

    @AppStorage(CompareOverlayMetrics.widthDefaultsKey) private var storedWidth: Double = 0
    @AppStorage(CompareOverlayMetrics.heightDefaultsKey) private var storedHeight: Double = 0
    /// The live size while a grip is held. Separate from the stored one so a drag redraws without
    /// writing to defaults every frame; the size is committed once, on release.
    @State private var dragging: CGSize?

    private var accent: Color { hue.accentColor }

    /// What every `.task(id:)` here is keyed on. The two paths, sorted, so opening the same pair
    /// from either side reuses the work rather than redoing it.
    private var pairKey: String { [left.path, right.path].sorted().joined(separator: "\n") }

    /// The size a drag measures from: always the committed one, never the live one, so the drag
    /// needs no starting size captured. Resolving each frame against the previous frame's result
    /// would compound the doubling in `ResizableCardSize.resized`, and the card would run away from
    /// the pointer.
    private var committedSize: CGSize {
        CompareOverlayMetrics.size(available: availableSize,
                                   stored: CGSize(width: storedWidth, height: storedHeight))
    }

    /// The size the card draws at: a live drag, else the committed one.
    private var size: CGSize { dragging ?? committedSize }

    private var facts: ComparePairFacts {
        ComparePairFacts.make(left: left, right: right,
                              scanRoot: scanRoot, providerName: providerName,
                              pages: pageFacts)
    }

    /// The two page counts this pair's facts strip states; see
    /// ``ComparePairFacts/pages(for:pairing:)``.
    ///
    /// Internal rather than private, as a seam: a SwiftUI `Text` can't be read back off a mounted
    /// view, so a test asserts here that the strip gets the pair's real kind and the lane's real
    /// answer rather than a constant.
    var pageFacts: (left: Int?, right: Int?)? {
        ComparePairFacts.pages(for: kind, pairing: pairing)
    }

    private var modes: [ComparePairMode] { ComparePairMode.available(for: kind) }

    /// The mode to draw in: the chosen one, unless this pair doesn't offer it.
    ///
    /// A kind change can strand the mode: `mode` is `@State` and the offered set comes from the
    /// pair's kind, so a surface handed a PDF pair while in `.textDiff` would draw the previous
    /// pair's line diff under a picker with nothing selected. Clamped here, not only reset on the
    /// pair task, so the render never disagrees with the picker, even for the frame between.
    private var activeMode: ComparePairMode { modes.contains(mode) ? mode : .sideBySide }

    /// The page pairing, or an empty one while the counts are still being asked for. Callers that
    /// need to know the difference read `pairing` itself.
    private var resolvedPairing: PagePairing { pairing ?? PagePairing(leftPages: 0, rightPages: 0) }

    var body: some View {
        // Built once and handed to both readers. `facts` allocates its rows and would be read once
        // per strip column and once for the verdict bar; one value also can't disagree with itself,
        // which is why the bar gets the viewer's facts rather than re-deriving them.
        let facts = self.facts
        return VStack(spacing: 0) {
            header
            Divider()
            if let notice { noticeBar(notice) }
            claimAndFacts(facts)
            Divider()
            if modes.count > 1 { modeBar }
            panes
            if kind == .pdf, resolvedPairing.stripLength > 1 {
                Divider()
                // `.equatable()`, because the surface's body re-runs on every publish of the
                // manager the host observes, and the strip is one view per page.
                PageStrip(pairing: resolvedPairing, states: pageStates, current: page,
                          accent: accent, isSearching: pageSearching) { page = $0 }
                    .equatable()
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            verdict(facts)
        }
        .frame(width: size.width, height: size.height)
        // `.focusable()` makes the keys below work, and `.focusEffectDisabled()` stops it
        // painting: otherwise macOS draws a focus ring around the whole card, which reads as a
        // stray highlight. The keys still arrive; the ring is the effect, not the focus.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            if let initialMode { mode = initialMode }
        }
        // Work doesn't outlive the surface. These are `Task.detached`/`Task` handles no
        // `.task(id:)` can reach, so without this a closed card would leave a line diff walking two
        // files, a page search queued on the serial lane, and a hash reading on, for answers
        // nothing will draw.
        .onDisappear {
            textDiffTask?.cancel()
            pageSearchTask?.cancel()
            verifyTask?.cancel()
        }
        // Both sides are classified at the root, not inside a pane. Only the side-by-side fallback
        // mounts the per-side preview, so a probe there would leave `sources` empty for ever when
        // the surface opens straight into a pixel mode (`4`): the raster refresh bails on "not
        // both readable" and nothing re-triggers it. A permanent spinner.
        //
        // Keyed on the path and the download latch, so a cloud-only side that lands re-probes,
        // turning its placeholder into a preview without a second poller.
        .task(id: probeKey(left)) { sources[left.path] = await probe(left.path) }
        .task(id: probeKey(right)) { sources[right.path] = await probe(right.path) }
        // Drag any edge or corner to resize, and the size is remembered. `ResizableCardGrips` is
        // the Help card's apparatus, shared through `Design`.
        .overlay {
            ResizableCardGrips(
                onDrag: { translation, grip in
                    dragging = ResizableCardSize.resized(
                        from: committedSize, by: translation, grip: grip,
                        minimum: CompareOverlayMetrics.minimum, within: availableSize)
                },
                onCommit: {
                    if let dragging {
                        storedWidth = dragging.width
                        storedHeight = dragging.height
                    }
                    dragging = nil
                })
        }
        // Plain keys anchored on the surface's focused root. The `keys:` overload, because it hands
        // the handler a `KeyPress`: `.onKeyPress(_:action:)` doesn't, so it can't tell a bare ←
        // from ⌘←, and `.onKeyPress` does deliver modified presses. `isPlainKeystroke`, not
        // `modifiers.isEmpty`: Caps Lock alone arrives as a modifier and would kill both keys.
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.isPlainKeystroke else { return .ignored }
            return chooseKeeper(press.key == .leftArrow ? left : right)
        }
        // **⏎ and esc are `.onKeyPress`, not key equivalents.** This is an in-window overlay: the
        // Duplicates cards, the panes and their search fields stay mounted under the scrim, so a
        // key equivalent here would be window-level, eating bare ⏎ and esc typed anywhere in the
        // window, on key-repeat. Only a real `.sheet`, being window-modal, can use
        // `.keyboardShortcut(.cancelAction)`; `BareKeyEquivalentScanTests` bans it in every
        // non-sheet file in this module.
        //
        // `.keypadEnter` beside `.return`: keyCode 76 sends U+0003, not U+000D, so `.return` alone
        // is deaf to one of the two Enter keycaps. `isPlainKeystroke`, not `modifiers.isEmpty`: the
        // keypad's Enter always carries `.numericPad` and `.function`, and Caps Lock rides on every
        // event while engaged.
        //
        // **⏎ closes; it never trashes.** The safe act keeps the default, and a destructive one
        // takes a deliberate click.
        .onKeyPress(keys: [.return, .keypadEnter], phases: .down) { press in
            guard press.isPlainKeystroke else { return .ignored }
            onClose()
            return .handled
        }
        // `keys:` rather than the single-key overload, which doesn't filter modifiers either;
        // every handler in this file checks `isPlainKeystroke`.
        .onKeyPress(keys: [.escape], phases: .down) { press in
            guard press.isPlainKeystroke else { return .ignored }
            onClose()
            return .handled
        }
        // 1–4 pick a mode by its position in what this pair offers (see
        // `ComparePairMode.forDigit(_:in:)`). A text pair offers two segments, so `2` there is its
        // Diff; a digit past the end is `.ignored` rather than reaching a segment not on screen.
        .onKeyPress(keys: ["1", "2", "3", "4"], phases: .down) { press in
            guard press.isPlainKeystroke,
                  let digit = Int(String(press.key.character)),
                  let picked = ComparePairMode.forDigit(digit, in: modes) else { return .ignored }
            mode = picked
            return .handled
        }
        // ⇞/⇟ page both sides: the surface owns the page, so there is one number and the pairing
        // clamps each side to its own last page.
        .onKeyPress(keys: [.pageUp, .pageDown], phases: .down) { press in
            guard press.isPlainKeystroke, resolvedPairing.stripLength > 1 else { return .ignored }
            let next = press.key == .pageUp ? page - 1 : page + 1
            page = min(max(0, next), resolvedPairing.stripLength - 1)
            return .handled
        }
        // ⌥ as a held modifier, not a chord: chords with ⌥ are banned app-wide (they fire from
        // inside the ⌥-hold keycap reveal). While it is down the two viewers stop mirroring, so
        // one pane can be moved on its own.
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
        // The page count each side actually has, which the strip and the pairing are built from.
        // Off the main actor and behind the serial lane, so a scan already parsing just makes it
        // arrive late.
        .task(id: pairKey) {
            // **A fresh pair inherits nothing.** Each of these is `@State` on a view the host can
            // hand a new pair without unmounting, and each holds an answer about the previous pair:
            // a strip of dots, a line diff, a verify verdict, a page number, and a mode this pair
            // may not offer. All of it resets here, above the `kind` guard, for every kind.
            pageStates = [:]
            page = 0
            textDiff = nil
            textNotes = []
            textDiffPairKey = nil
            // Not cancelled here, deliberately. The two tasks re-key on the same render and SwiftUI
            // doesn't promise which starts first, so cancelling from this one could hit a walk the
            // other just started for the new pair, leaving the diff pane empty with nothing to
            // re-trigger it. `refreshTextDiff` cancels the previous walk as it starts the next; a
            // walk left running is bounded by `TextPairDiff.maxDiffWork` and lands nowhere, because
            // its key is re-checked before anything is written.
            focusedRegion = nil
            verify = .idle
            // Rotated, not just cleared: the one token the pair change must move itself.
            // `rasterToken` and `textDiffToken` are taken inside `.task(id:)`s keyed on the pair,
            // so they rotate on their own. A verify is started from a button and nothing re-runs
            // it, so without this an in-flight hash would land its verdict about the previous
            // pair's files under the new pair's name.
            verifyToken = UUID()
            verifyTask?.cancel()
            clearRasters()
            renderOutcome = .rendering
            pageSearchToken = UUID()
            pageSearchTask?.cancel()
            pageSearching = false
            // A zoom is about the document the reader was reading: a new pair opens fitted, as if
            // the surface had just been opened on it.
            pdfZoom = nil
            if !modes.contains(mode) { mode = .sideBySide }
            guard kind == .pdf else {
                pairing = PagePairing(leftPages: 0, rightPages: 0)
                return
            }
            pairing = nil
            async let leftCount = PagePairRaster.pageCount(path: left.path)
            async let rightCount = PagePairRaster.pageCount(path: right.path)
            pairing = PagePairing(leftPages: await leftCount ?? 0, rightPages: await rightCount ?? 0)
        }
        // One in-flight render per side, re-keyed on the page and the mode's need for a raster.
        // `.task(id:)` cancels it when the page changes, and a cancelled render that hasn't reached
        // the PDF lane never opens or draws its page, so paging through a 300-page document
        // doesn't queue 300 renders behind a scan.
        .task(id: rasterKey) { await refreshRasters() }
        // A page search doesn't outlive the mode that started it. ↑/↓ only searches in a pixel
        // mode, and a search still walking when the reader leaves would move the page under
        // whatever they switched to. Cancelled rather than finished: the verdicts it wrote stay in
        // the strip.
        .onChange(of: activeMode) { _, _ in
            pageSearchToken = UUID()
            pageSearchTask?.cancel()
            pageSearching = false
        }
        // Re-read when the pair changes, and on the first entry into the diff. A text pair the
        // reader never switches to Diff costs nothing; one they switch away from and back keeps
        // what it has (see `textDiffPairKey`).
        .task(id: "\(pairKey)|\(activeMode == .textDiff)") { await refreshTextDiff() }
        // ↑/↓ step between what changed, in the mode's unit: text regions in the diff (a
        // twelve-line replacement is one change, not twelve presses), and differing pages in a
        // visual mode, where ⇞/⇟ already move one page and the reader hunts the next amber dot.
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            guard press.isPlainKeystroke else { return .ignored }
            let direction = press.key == .upArrow ? -1 : 1
            if activeMode == .textDiff {
                guard let diff = textDiff, !diff.regions.isEmpty else { return .ignored }
                focusedRegion = TextPairDiff.steppedRegion(from: focusedRegion,
                                                           direction: direction,
                                                           count: diff.regions.count)
                return .handled
            }
            guard showsOverlayModes, resolvedPairing.stripLength > 1 else { return .ignored }
            stepToDifferingPage(direction: direction)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare \(title)")
    }

    // MARK: Header

    /// Glyph, name, and the kind as a pill beside it rather than grey text beneath. Under the title
    /// it would read as a subtitle, when it is a claim about the pair, the one the surface is
    /// arguing about; as a pill it is the badge the group card wears, where the reader met it.
    private var header: some View {
        HStack(spacing: 10) {
            FileTypeGlyph.view(name: title, isDirectory: false, pointSize: 16)
                .frame(width: 19, height: 19)
            Text(title)
                .scaledFont(.system(size: 14.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !subtitle.isEmpty { kindPill }
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            // Frosted and Clear: a glass capsule like every bar button (`ChromeGlass`).
            .chromeGlassGround(.capsule, outset: 2)
            .accessibilityLabel("Close compare")
            .help(ShortcutHint.tooltip("Close", "esc"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private var kindPill: some View {
        Text(subtitle)
            .scaledFont(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(Color.secondary.opacity(0.12))
            }
            .fixedSize()
    }

    // MARK: The host's notice

    /// A line the host wants above the facts: today, the duplicates host saying a rescan landed
    /// under the open surface. The previews are still worth reading and only the verdict has to
    /// stop, so the surface says so rather than being torn down under the user.
    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text(text)
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
    private func claimAndFacts(_ facts: ComparePairFacts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Verify sits beside the claim it re-checks, not at the far edge, where it would float
            // alone far from the sentence that gives it meaning.
            if claimHeadline != nil || offersVerify {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let claimHeadline {
                        Text(claimHeadline)
                            .scaledFont(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if offersVerify { verifyControl }
                    Spacer(minLength: 0)
                }
            }
            if verify != .idle {
                Text(verify.caption)
                    .scaledFont(.system(size: 11.5, weight: verify == .differed ? .semibold : .regular))
                    .foregroundStyle(verify == .differed ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            factsGrid(facts)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var verifyControl: some View {
        HStack(spacing: 6) {
            if verify == .running { ProgressView().controlSize(.small) }
            Button("Verify Now") { runVerify() }
                .buttonStyle(.hoverAffordance(.segment, tint: accent))
                .controlSize(.small)
                .disabled(verify == .running)
                .help("Checksum both files to confirm they are still identical right now")
        }
    }

    /// The facts, as two blocks, one over each pane.
    ///
    /// The card is two columns and this is their top. A single table with a label gutter would push
    /// both value columns off their panes, and a centre spine would drag long paths into the
    /// middle. Two self-contained blocks keep each side's facts, keeper control and preview in one
    /// column, top to bottom.
    ///
    /// The labels repeat, which is the cost: at 9pt tertiary they are a gutter, not content, and a
    /// value never sits over the wrong pane.
    private func factsGrid(_ facts: ComparePairFacts) -> some View {
        HStack(alignment: .top, spacing: 10) {
            factsBlock(facts, \.left)
            factsBlock(facts, \.right)
        }
    }

    private func factsBlock(_ facts: ComparePairFacts,
                            _ side: KeyPath<ComparePairFacts.Row, String>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(facts.rows) { row in
                GridRow {
                    Text(row.label.uppercased())
                        .scaledFont(.system(size: 9, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)
                    factValue(row[keyPath: side], differs: row.differs,
                              // A path truncates from the head: the deepest folders tell two
                              // copies apart, and both share the provider name. A name truncates
                              // in the middle, where the extension and any "(1)" live.
                              truncation: row.field == .location ? .head : .middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factValue(_ text: String, differs: Bool,
                           truncation: Text.TruncationMode) -> some View {
        Text(text)
            .scaledFont(.system(size: 11.5, weight: differs ? .semibold : .regular,
                                design: .monospaced))
            .foregroundStyle(differs ? Color.primary : Color.secondary)
            .lineLimit(1)
            .truncationMode(truncation)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Panes

    /// The mode segments, plus whatever the current mode owes the reader.
    private var modeBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(modes) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accentedSegments(hue)
            .labelsHidden()
            .fixedSize()
            .help(ShortcutHint.tooltip("Choose how to compare the two copies", "1–\(modes.count)"))
            .accessibilityLabel("Compare mode")
            if activeMode == .onion {
                Slider(value: $onionOpacity, in: 0...1)
                    .frame(maxWidth: 160)
                    .help("Fade the right copy over the left — drag right to see more of it")
                    .accessibilityLabel("Onion blend")
            }
            // The mode's standing caveat says "with no alignment", which is false when a de-skew
            // was applied, so the caveat is replaced rather than joined: one sentence saying the
            // pages weren't aligned and one saying they were is worse than either.
            if let caveat = alignmentCaveat ?? activeMode.caveat {
                Text(caveat)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The count the callouts are an index of. Gated on the page being resolved, as the size
            // caveat below is: a count over a pending render describes the previous page.
            if activeMode == .difference, pageStates[page]?.isResolved == true,
               let regions = ChangedRegionCallouts.caption(
                    regionCount: pageComparison.regions.count) {
                Text(regions)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Only where a raster answered and the sizes differ: a caveat while the render is
            // pending would describe the previous page, and an empty one would reserve space for
            // nothing.
            if !sizeCaveat.isEmpty, pageStates[page]?.isResolved == true {
                Text(sizeCaveat)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// What replaces the mode's "no alignment" caveat when a de-skew was applied.
    ///
    /// "Best effort" is in the sentence because it is the truth about the method: a coarse
    /// correlation over a 256-pixel grid, fine for scanner skew and nothing like a registration
    /// pass, and a reader told only "aligned" would read the remaining glow as content. Nil where
    /// nothing was applied (not attempted, or attempted and refused); the mode's caveat covers it.
    ///
    /// Gated on the page being resolved for `sizeCaveat`'s reason: a caption printed over a
    /// pending render describes the previous page.
    private var alignmentCaveat: String? {
        guard activeMode == .difference, pageStates[page]?.isResolved == true else { return nil }
        return pageRegistration?.caption
    }

    /// Disclosed rather than hidden: a rescaled comparison resamples, so its figure is a weaker
    /// claim than a matched pair's.
    private var sizeCaveat: String {
        guard let left = rasters.left, let right = rasters.right,
              left.width != right.width || left.height != right.height else { return "" }
        return "Different page sizes — rescaled to compare."
    }

    @ViewBuilder
    private var panes: some View {
        Group {
            switch activeMode {
            case .sideBySide:
                sideBySidePanes
            case .textDiff:
                textDiffPane
            case .swipe, .onion, .difference:
                VisualPairModeView(mode: activeMode, left: rasters.left, right: rasters.right,
                                   outcome: renderOutcome,
                                   leftName: left.name, rightName: right.name,
                                   difference: pageComparison.image,
                                   accent: accent,
                                   changedRegions: pageComparison.regions,
                                   swipeFraction: $swipeFraction, onionOpacity: $onionOpacity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                    }
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The line diff, or the reason there is none. A refusal names which side and why (too
    /// large, not downloaded, not text) rather than leaving an empty pane to guess at.
    @ViewBuilder
    private var textDiffPane: some View {
        Group {
            if let textDiff {
                TextPairDiffView(diff: textDiff, notes: textNotes, accent: accent,
                                 focusedRegion: $focusedRegion)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                    }
            } else {
                VStack(spacing: 8) {
                    if textNotes.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        ForEach(textNotes, id: \.self) { note in
                            Text(note)
                                .scaledFont(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
    }

    /// One pass's answer. See ``TextPairDiffPipeline/Outcome``, where the reading, the pre-filter,
    /// the walk and the notes live, so the editor's divergence overlay asks the same question in the
    /// same order rather than keeping a second copy.
    private typealias TextDiffResult = TextPairDiffPipeline.Outcome

    /// Reads both sides and diffs them, off the main actor: bounded and encoding-tolerant (see
    /// ``BoundedTextRead``), and a Myers pass over a 4 MB file is real work with no place on the
    /// actor that draws the window.
    ///
    /// Token-guarded, like the raster path. `.task(id:)` cancels the awaiting task, but a
    /// `Task.detached` neither observes that nor finishes in start order: a large pair's diff could
    /// resume after a small pair's was drawn and overwrite it under the wrong name. The token is
    /// taken before the hop and re-read after it.
    private func refreshTextDiff() async {
        // Not the diff's mode: nothing is cleared and nothing is read. Leaving `.textDiff` keeps
        // the diff, so coming back needn't re-read both files; the pane just isn't drawn.
        guard activeMode == .textDiff else { return }
        guard kind == .text else {
            // A pair that isn't text has no diff, and anything held here is the previous pair's,
            // which `textDiffPane` would draw the moment the mode comes back. The focus goes too:
            // it points into regions that no longer exist.
            textDiff = nil
            textNotes = []
            focusedRegion = nil
            textDiffPairKey = nil
            return
        }
        // Already answered for these two files. Leaving and re-entering the mode is no reason to
        // read 8 MB again.
        guard textDiffPairKey != pairKey else { return }
        // The pair this pass is about, read once. The view can be handed a new pair while the walk
        // is in flight, and `pairKey` after the await would then name the wrong two files, which
        // the memo would go on to claim.
        let key = pairKey
        let token = UUID()
        textDiffToken = token
        textDiffTask?.cancel()
        let leftPath = left.path, rightPath = right.path
        let task = Task.detached(priority: .userInitiated) { () -> TextDiffResult in
            // The reads stay inside the detached task (two `contents(atPath:)` calls of up to
            // 4 MiB each), and the ordering after them is ``TextPairDiffPipeline/diff``'s. The walk
            // stops when this task is cancelled, which is what the handle above is for.
            TextPairDiffPipeline.diff(left: BoundedTextRead.read(path: leftPath),
                                      right: BoundedTextRead.read(path: rightPath),
                                      isCancelled: { Task.isCancelled })
        }
        textDiffTask = task
        let result = await task.value
        guard textDiffToken == token, key == pairKey, !result.cancelled else { return }
        // Logged where the result lands, so a superseded pass says nothing and the logged note is
        // the one the reader sees. A refusal is the whole answer, hence a warning; a coarse row is
        // a diff with less in it than usual.
        if result.diff == nil, !result.notes.isEmpty {
            Logger.shared.warning(
                "[compare] no line diff for \(left.path) vs \(right.path): \(result.notes.joined(separator: " "))")
        } else if let diff = result.diff, diff.coarseRows > 0 {
            Logger.shared.info(
                "[compare] \(diff.coarseRows) row(s) too long for the word pass in \(left.path) vs \(right.path)")
        }
        textDiff = result.diff
        textNotes = result.notes
        focusedRegion = nil
        textDiffPairKey = key
    }

    /// Whether both documents actually opened. A page count of zero is a document that wouldn't
    /// open (encrypted, truncated, or not really a PDF), and `stripLength` can't say so because it
    /// is the longer of the two: 0 against a healthy 6 reads as 6, and the typed viewer would mount
    /// a pane that can only ever be grey.
    private var bothSidesOpened: Bool {
        resolvedPairing.leftPages > 0 && resolvedPairing.rightPages > 0
    }

    /// The line explaining why a pair that should have earned a typed viewer is showing plain
    /// previews, or nil when nothing is wrong. Named per side, because the reader is looking at two
    /// similarly named files and needs to know which one is the problem.
    private var unopenableCaption: String? {
        guard bothSidesReadable else { return nil }
        switch kind {
        case .pdf:
            // Reached only once the page counts have landed: while they are in flight the surface
            // shows a spinner from `stillResolvingTypedViewer` and never renders this branch.
            guard !bothSidesOpened else { return nil }
            let leftClosed = resolvedPairing.leftPages == 0
            let rightClosed = resolvedPairing.rightPages == 0
            if leftClosed && rightClosed { return "Neither copy could be opened." }
            let name: String = leftClosed ? left.name : right.name
            return "“\(name)” could not be opened, so these previews scroll on their own."
        case .image:
            guard case .failed(let leftFailed, let rightFailed) = renderOutcome else { return nil }
            if leftFailed && rightFailed { return "Neither copy could be rendered." }
            let name: String = leftFailed ? left.name : right.name
            return "“\(name)” could not be rendered, so these previews scroll on their own."
        case .text, .other:
            return nil
        }
    }

    /// Side by side, in whichever viewer the pair's kind earns.
    ///
    /// A typed viewer replaces the Quick Look panes only where it is genuinely better. A cloud-only
    /// or missing side has nothing to open, so the pair falls back to the per-side panes that can
    /// say why; a `PDFView` given a placeholder path shows an empty grey box.
    @ViewBuilder
    private var sideBySidePanes: some View {
        if kind.hasSyncedViewer && stillResolvingTypedViewer {
            // Neither panes nor a decision yet. A kind about to get a typed viewer must not flash
            // the Quick Look fallback first, which would swap the whole pane a moment later and
            // spin up a Quick Look extension for nothing. `pairing == nil` is what tells "the count
            // is in flight" from "this PDF opens to nothing", which is why it is optional.
            //
            // Drawn in the frame the viewer will occupy, headers and all, so the keeper control
            // (which a reader may want to click while the document opens) doesn't pop in and shift
            // everything down when the wait ends. All three branches share this shape.
            typedPanes {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if kind == .pdf, bothSidesReadable, bothSidesOpened {
            typedPanes {
                PDFPairView(leftPath: left.path, rightPath: right.path,
                            page: page, pairing: resolvedPairing, syncSuspended: optionHeld,
                            // Scrolling also changes page, so the strip and the pixel modes follow
                            // the panes. Clamped to the strip, which runs to the longer document: a
                            // report past its end would select a chip that isn't drawn.
                            onPageChange: { reported in
                                let last = max(0, resolvedPairing.stripLength - 1)
                                let clamped = min(max(0, reported), last)
                                if clamped != page { page = clamped }
                            },
                            zoom: pdfZoom,
                            onZoomChange: { pdfZoom = $0 })
            }
        } else if kind == .image, bothSidesReadable, !renderOutcome.didFail {
            typedPanes {
                ImagePairView(left: rasters.left, right: rasters.right, syncSuspended: optionHeld)
            }
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    pane(left)
                    pane(right)
                }
                // Say why these are plain previews and not the typed viewer, or the reader sees a
                // surface quietly less than for the pair beside it, with no idea which copy is why.
                if let caption = unopenableCaption {
                    Text(caption)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let caption = kind.unsyncedCaption, bothSidesReadable {
                    Text(caption)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func typedPanes(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                paneHeader(left)
                paneHeader(right)
            }
            content()
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Both sides have content on disk. A typed viewer can't say "this one is a cloud
    /// placeholder"; the per-side Quick Look panes can, so they are the fallback.
    private var bothSidesReadable: Bool {
        sources[left.path] == .quickLook && sources[right.path] == .quickLook
    }

    /// Whether a kind that earns a typed viewer is still waiting on the facts that decide it:
    /// either side unclassified, the page counts not yet asked for, or the first raster not yet
    /// decoded.
    ///
    /// An image pair waits for its raster: `ImagePairView` draws two `CGImage`s decoded off the
    /// main actor, so mounting it before the first render lands shows two empty scroll views, the
    /// silence ``PairRenderOutcome`` exists to prevent. On a 100-megapixel raw that is seconds.
    ///
    /// `bothSidesReadable` is in the image term because `refreshRasters` bails without it, leaving
    /// `renderOutcome` at `.rendering` for ever: a cloud-only side would spin here instead of
    /// falling through to the placeholder pane that offers to download it. `.failed` isn't waiting
    /// either: it falls through to the Quick Look panes and the caption naming the copy.
    private var stillResolvingTypedViewer: Bool {
        TypedViewerReadiness.isStillResolving(
            kind: kind,
            sidesClassified: sources[left.path] != nil && sources[right.path] != nil,
            pageCountsResolved: pairing != nil,
            bothSidesReadable: bothSidesReadable,
            outcome: renderOutcome,
            hasRasters: rasters.left != nil && rasters.right != nil)
    }

    // MARK: Rasters

    /// What a render is keyed on. The mode is in it because side by side on a PDF needs no raster
    /// (the two `PDFView`s draw themselves), so entering a pixel mode starts the work and leaving
    /// stops redoing it. `bothSidesReadable` is in it (through ``decodeKey``) because the refresh
    /// bails until the sides are classified, and without the term nothing would re-key the task
    /// once they are.
    private var rasterKey: String {
        "\(decodeKey)|\(showsOverlayModes)|\(wantsAlignedDifference)"
    }

    /// What the two rasters depend on: everything in `rasterKey` except the mode.
    ///
    /// Split out so a mode change doesn't re-run the decode. For an image pair the rasters are
    /// needed in every mode, so entering or leaving a pixel mode must not throw away rasters
    /// already in hand to answer a question about the comparison.
    ///
    /// Held against ``heldRasterKey``, which names the pair, page and side the rasters on hand are
    /// actually of.
    private var decodeKey: String {
        "\(pairKey)|\(page)|\(kind.rawValue)|\(needsRasters)"
            + "|\(bothSidesReadable)|\(resolvedPairing.stripLength)"
    }

    /// Whether the mode on screen wants the expensive comparison: the de-skew, and the difference
    /// raster it is drawn against. One property, because it is one mode.
    ///
    /// The difference raster is a third full-page image and a pass over two more, which swipe and
    /// onion never draw. The de-skew costs far more (about 590 ms against 8 ms for the plain
    /// comparison on a 1600×2070 page, nearly all of it `PageRegistrationEstimator.estimate`), and
    /// outside the difference mode nothing reads it: `alignmentCaveat` and the callouts are gated
    /// on `.difference`.
    ///
    /// This keeps the strip uniform: `comparedState(atPage:)`, the walk that fills `pageStates` for
    /// the ↑/↓ search, uses the plain unaligned `BitmapDiff.compare`, so outside the difference mode
    /// the visible page's dot is unaligned like the rest. Inside it, the alignment is read and
    /// captioned.
    private var wantsAlignedDifference: Bool { activeMode == .difference }

    /// Whether the diff is being looked at, as opposed to the rasters merely being needed. An image
    /// pair needs its rasters in every mode (`ImagePairView` draws them), but side by side shows
    /// neither the difference image nor the comparison, so computing them would be spent on every
    /// image pair opened, for a number nobody reads.
    private var showsOverlayModes: Bool { activeMode != .sideBySide }

    private var needsRasters: Bool {
        kind.hasPixelModes && (activeMode != .sideBySide || kind == .image)
    }

    /// Moves to the next page in `direction` whose comparison found a difference.
    ///
    /// A bounded search, because the strip doesn't already know: `pageStates` is filled by the
    /// raster refresh for the current page alone, so on a fresh pair the step has to go and look.
    /// Verdicts already held are free; ``PageDifferenceStepper/renderBudget`` caps how many pages one
    /// press renders, and a second press resumes from what the first learned.
    ///
    /// The states it writes are the ones the strip draws, so a search visibly fills the strip as it
    /// walks, which tells the reader the key did something when the answer is far away.
    ///
    /// Token-guarded like the raster path, for the same race: a search still walking when the pair
    /// or the page moves under it would land on a page nobody asked for.
    private func stepToDifferingPage(direction: Int) {
        let token = UUID()
        pageSearchToken = token
        switch PageDifferenceStepper.plan(from: page, direction: direction,
                                          stripLength: resolvedPairing.stripLength,
                                          states: pageStates) {
        case .nothingToFind:
            return
        case .jump(let destination):
            page = destination
        case .examine(let candidates, let fallback):
            pageSearching = true
            pageSearchTask?.cancel()
            let task = Task {
                defer { if pageSearchToken == token { pageSearching = false } }
                for candidate in candidates {
                    // Both, for different questions: the token says a newer search superseded this
                    // one; cancellation says nobody wants any search (the surface closed, or the
                    // pair moved on).
                    guard pageSearchToken == token, !Task.isCancelled else { return }
                    let state = await comparedState(atPage: candidate)
                    guard pageSearchToken == token, !Task.isCancelled else { return }
                    pageStates[candidate] = state
                    if PageDifferenceStepper.isDifference(state) {
                        page = candidate
                        return
                    }
                }
                // None of them differed, but the walk already passed a page that does (see
                // `Plan.examine`). Landing there stops the press reading as a dead key.
                if let fallback { page = fallback }
            }
            pageSearchTask = task
        }
    }

    /// One page pair's verdict, rendered and compared off the main actor.
    ///
    /// At `compareLongEdge`, the resolution the page on screen is judged at. A cheaper render would
    /// put dots decided by different arithmetic in one strip, and the smaller one can't prove
    /// sameness (see ``PageDifferenceStepper``).
    private func comparedState(atPage index: Int) async -> PageDiffState {
        guard resolvedPairing.isComparable(at: index) else { return .oneSided }
        let kind = self.kind
        async let leftImage = PagePairRaster.render(path: left.path, kind: kind,
                                                    page: resolvedPairing.leftIndex(at: index),
                                                    longEdge: PagePairRaster.compareLongEdge)
        async let rightImage = PagePairRaster.render(path: right.path, kind: kind,
                                                     page: resolvedPairing.rightIndex(at: index),
                                                     longEdge: PagePairRaster.compareLongEdge)
        guard let l = await leftImage, let r = await rightImage else { return .unrenderable }
        let result = await Task.detached(priority: .utility) {
            BitmapDiff.compare(l.cgImage, r.cgImage)
        }.value
        return PageDiffState.from(result)
    }

    /// Drops the rasters and orphans whatever is still rendering them.
    ///
    /// One helper because both clearers must rotate the token. `.task(id:)` cancellation is
    /// cooperative: a render already drawing finishes and its awaits resume anyway, so the only
    /// thing between a superseded render and the state it would overwrite is
    /// `guard rasterToken == token`. A clear that left the token alone would leave that guard
    /// satisfied, and the run would re-fill `rasters` and `pageComparison` just after they were
    /// cleared, ready to show as this page's answer when an overlay mode comes back.
    ///
    /// The pair reset clears these too, where rotating also matters because the pair has changed,
    /// so a landing render would describe two files no longer on screen.
    ///
    /// **Rotate first, then clear**, or the clear is what the stale render overwrites.
    private func clearRasters() {
        rasterToken = UUID()
        rasters = (nil, nil)
        pageRegistration = nil
        pageComparison = PageComparison()
        // The two memos describe what was just dropped; a memo outliving its value would let the
        // next refresh reuse rasters that are no longer there.
        heldRasterKey = nil
        heldComparisonKey = nil
        heldComparisonAligned = false
    }

    /// Renders both sides of the current page and diffs them.
    ///
    /// **The lane is held for open and draw only.** `PagePairRaster` releases it before returning,
    /// and the diff (plain arithmetic over two buffers, not PDFKit) runs off it. Holding the lane
    /// across the pixel work would stall a running scan's extractions behind a compare.
    private func refreshRasters() async {
        guard needsRasters, bothSidesReadable else {
            clearRasters()
            // No answer rather than a verdict: nothing was asked of the renderer, and a `.failed`
            // left from a previous page would caption a pane merely waiting for its first render.
            renderOutcome = .rendering
            return
        }
        let token = UUID()
        rasterToken = token
        let decodeKey = self.decodeKey

        // The decode is skipped when the rasters on hand are already of this page, and only the
        // mode changed (see ``decodeKey``).
        var pair: (left: CGImage, right: CGImage)?
        if heldRasterKey == decodeKey, let l = rasters.left, let r = rasters.right {
            pair = (l, r)
        }

        if pair == nil {
            renderOutcome = .rendering
            let leftPage = resolvedPairing.leftIndex(at: page)
            let rightPage = resolvedPairing.rightIndex(at: page)
            let kind = self.kind
            async let leftImage = PagePairRaster.render(path: left.path, kind: kind,
                                                        page: leftPage,
                                                        longEdge: PagePairRaster.compareLongEdge)
            async let rightImage = PagePairRaster.render(path: right.path, kind: kind,
                                                         page: rightPage,
                                                         longEdge: PagePairRaster.compareLongEdge)
            let (l, r) = (await leftImage, await rightImage)
            // A raster that lands after the user has paged on describes a page nobody is looking
            // at. A cancelled one may be no raster at all (`PagePairRaster.render`), not a page
            // that failed to render.
            guard rasterToken == token, !Task.isCancelled else { return }
            rasters = (l?.cgImage, r?.cgImage)
            heldRasterKey = decodeKey
            heldComparisonKey = nil
            guard let l, let r else {
                pageComparison = PageComparison()
                pageStates[page] = .unrenderable
                // The same finding the strip just recorded, told to the panes, which otherwise know
                // only that they have no image, as a render in flight also looks.
                renderOutcome = .failed(left: l == nil, right: r == nil)
                // Logged for the visible page only: the page search renders many and would turn a
                // broken document into a hundred lines. Without it the log would say nothing when
                // someone reports a file that couldn't be rendered.
                let unread = [l == nil ? left.path : nil,
                              r == nil ? right.path : nil].compactMap { $0 }
                Logger.shared.warning(
                    "[compare] page \(page + 1) would not render: \(unread.joined(separator: ", "))")
                return
            }
            pair = (l.cgImage, r.cgImage)
        }
        renderOutcome = .ready
        guard let pair else { return }
        guard showsOverlayModes else {
            // The rasters are up (the image viewer draws them); nothing here is being compared.
            pageComparison = PageComparison()
            heldComparisonKey = nil
            return
        }
        let wantsAligned = wantsAlignedDifference
        // What is held may already be better than this mode asks for, and then it stays (see
        // ``PageComparisonReuse``): recomputing an unaligned verdict over an aligned one would
        // change the page's dot under a mode press that changed nothing about it.
        guard !PageComparisonReuse.isEnough(held: heldComparisonKey, decode: decodeKey,
                                            heldAligned: heldComparisonAligned,
                                            wantsAligned: wantsAligned) else { return }
        let (l, r) = (SendableImage(pair.left), SendableImage(pair.right))
        // Off the main actor: the buffer loop is milliseconds of arithmetic on a 1600px page, with
        // no place on the actor that draws the window.
        let comparison = await Task.detached(priority: .utility) {
            () -> (SendableImage?, BitmapDiffResult?) in
            // Aligned only for the mode that reads the alignment, and the difference raster comes
            // out of the same call rather than a second pass over its own copies of both pages.
            // See ``wantsAlignedDifference`` for why the other overlay modes skip both.
            guard wantsAligned else { return (nil, BitmapDiff.compare(l.cgImage, r.cgImage)) }
            let outcome = BitmapDiff.compareAligning(l.cgImage, r.cgImage,
                                                     wantsDifferenceImage: true)
            return (outcome.difference.map(SendableImage.init), outcome.result)
        }.value
        guard rasterToken == token else { return }
        heldComparisonKey = decodeKey
        // The registration is nil for an unaligned pass, which keeps `alignmentCaveat` from
        // captioning it as de-skewed: the caption is read straight off `pageRegistration`.
        heldComparisonAligned = wantsAligned
        pageRegistration = comparison.1?.registration
        // The only trace an applied de-skew leaves: the caption goes with the sheet, and when a
        // pair that glowed oddly is reported later, the log is the only answer to whether the page
        // was rotated before comparing, and by how much. Info, since it is that only answer: one
        // line per page compared, and `PageComparisonReuse` keeps a re-render from repeating it.
        if let applied = comparison.1?.registration {
            Logger.shared.info("""
                [compare] page \(page + 1) aligned before comparing: \
                \(String(format: "%.2f", applied.degrees))°, \
                (\(String(format: "%.1f", applied.dx)), \(String(format: "%.1f", applied.dy))) px, \
                confidence \(String(format: "%.3f", applied.confidence))
                """)
        }
        pageComparison = PageComparison(image: comparison.0?.cgImage,
                                        regions: comparison.1?.changedRects ?? [])
        pageStates[page] = resolvedPairing.isComparable(at: page)
            ? PageDiffState.from(comparison.1)
            : .oneSided
    }

    private func pane(_ copy: DuplicateCopy) -> some View {
        VStack(spacing: keeperPath == nil ? 0 : 6) {
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

    /// A keeper picker only where there is a keeper to pick. With `keeperPath` nil (the
    /// Differences host, where two files at one relative path on two roots are not a group and
    /// nothing is kept) there is no header: disabled "Keep this" buttons would advertise a choice
    /// that doesn't exist.
    @ViewBuilder
    private func paneHeader(_ copy: DuplicateCopy) -> some View {
        if let keeperPath {
            let isKeeper = copy.path == keeperPath
            let marker = DuplicateKeeperMarker.style(allowsKeeperChoice: allowsKeeperChoice,
                                                     isKeeper: isKeeper)
            // The keeper control and nothing else: the file's name is already the Name fact just
            // above. One statement per fact.
            CompareKeeperHeaderRow(
                control: CompareKeeperControl.control(isKeeper: isKeeper, marker: marker),
                accessibilityLabel: marker.accessibilityLabel, accent: accent,
                onKeepInstead: { chooseKeeper(copy) })
        }
        // With no keeper (the Differences host) the row collapses entirely: the facts block above
        // already names and locates each side.
    }

    @ViewBuilder
    private func previewArea(_ copy: DuplicateCopy) -> some View {
        let source = sources[copy.path]
        ZStack {
            Color.secondary.opacity(0.05)
            switch source {
            case .quickLook:
                // The existing representable, unmodified. Its `dismantleNSView` close keeps a
                // Quick Look extension process from leaking per file previewed.
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
    }

    /// Re-probes when the path changes and when a download this surface is watching concludes:
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
                    .help("Fetch this file’s content from the provider so it can be previewed")
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)])
            }
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .controlSize(.small)
        }
        .padding(16)
    }

    // MARK: Actions

    /// The one keeper flip, for the pane button and for ←/→ alike. Returns `.ignored` when there is
    /// nothing to flip, so an arrow key over a stale surface falls through rather than being
    /// swallowed.
    @discardableResult
    private func chooseKeeper(_ copy: DuplicateCopy) -> KeyPress.Result {
        guard allowsKeeperChoice, keeperPath != nil, copy.path != keeperPath else { return .ignored }
        onChooseKeeper(copy.path)
        return .handled
    }

    private func requestDownload(_ copy: DuplicateCopy) {
        do {
            try MaterializationStatus.download(atPath: copy.path)
            // This surface owns its own watch, so no pane latches a download it didn't start, the
            // double watch the pane-scoped token exists to prevent.
            downloads.begin(CloudDownloadRequest(path: copy.path, paneToken: .compareCopies))
        } catch {
            // Works for iCloud and was seen working on Google Drive; Dropbox and OneDrive are
            // untested. When it throws, the fallback is Finder, which can reach the provider's
            // extension.
            Logger.shared.warning("[compare] download refused for \(copy.path): \(error.localizedDescription) — revealing in Finder")
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)])
        }
    }

    private func runVerify() {
        guard verify != .running else { return }
        verify = .running
        let token = UUID()
        verifyToken = token
        let leftPath = left.path
        let rightPath = right.path
        let hash = self.hash
        verifyTask = Task { @MainActor in
            async let l = hash(leftPath)
            async let r = hash(rightPath)
            let outcome = ComparePairVerify.outcome(left: await l, right: await r)
            // A completion from a verify the user has already superseded answers a question
            // nobody is asking any more.
            guard verifyToken == token else { return }
            verify = outcome
        }
    }
}

// MARK: - The Duplicates host's sheet

/// Which copy a live duplicate group is keeping, as one compared pair can see it: three
/// answers, because a group may hold more copies than the two on screen.
///
/// A type so the surface never falls back to the left pane when the group's keeper is neither side:
/// that would draw a keeper marker on a copy nothing keeps, with the trash enabled beside it, and
/// the destructive act would run against a keeper that exists only on this surface.
///
/// Produced by ``CompareCopiesOverlay/keeperStanding(of:in:)``, a pure function of a pair and a
/// group, asserted as one: `sheet(available:)` is private, and a `some View` can't be interrogated.
enum PairKeeperStanding: Equatable {
    /// The group keeps one of these two, at this path.
    case inPair(String)
    /// The group keeps a copy that is neither of these two. The facts on screen are current; the
    /// verdict has no subject.
    case outsidePair(name: String)
    /// No live group holds both paths any more: the scan moved on under an open surface.
    case noLiveGroup

    /// The keeper path to draw a marker for, or nil for no marker at all.
    ///
    /// Nil in both other cases, because neither knows. With the keeper outside the pair, marking
    /// either side would be a false claim; with no live group, nothing is being kept, and the notice
    /// already says the facts are old. So the header row collapses, as on the Differences host.
    var keeperPath: String? {
        if case .inPair(let path) = self { return path }
        return nil
    }

    /// Whether the destructive verdict may be offered at all.
    var offersVerdict: Bool {
        if case .inPair = self { return true }
        return false
    }
}

/// ``FilePairCompareView`` with the Duplicates verdict bar under it: a keeper, a single-copy
/// trash, and Done.
///
/// Everything above that bar is the shared component; this wrapper maps a duplicate group's
/// vocabulary (match kind, keeper, protected copies, a stale scan) onto a viewer that knows none
/// of it.
struct CompareCopiesSheet: View {

    let pair: DuplicateComparePair
    /// Which copy the live group is keeping, as this pair can see it: the one value the keeper
    /// markers, the picker, the notice and the destructive verdict are all read off.
    ///
    /// One value rather than separate keeper, outside-keeper and stale fields, which could combine
    /// into a surface that withheld its verdict without saying why, or claimed a keeper while
    /// reporting itself stale. The question has exactly three answers.
    let standing: PairKeeperStanding
    let allowsKeeperChoice: Bool
    /// Copies that may never be removed: inside a folder another group is keeping.
    let protectedPaths: Set<String>
    let scanRoot: String?
    let providerName: String?
    let hue: LiquidGlassHue
    let availableSize: CGSize

    var onChooseKeeper: (String) -> Void
    /// `(copy to trash, keeper)`.
    var onTrash: (DuplicateCopy, DuplicateCopy) -> Void
    var onClose: () -> Void

    var probe: @Sendable (String) async -> ColumnPreviewSource = {
        await ColumnPreviewProbe.read(path: $0).source
    }
    var hash: @Sendable (String) async -> FileContentVerifier.HashOutcome = {
        await FileContentVerifier.hashOutcome(filePath: $0, cache: ContentHashCache.shared)
    }
    /// Forwarded to ``FilePairCompareView/initialMode``; tests only, see there.
    var initialMode: ComparePairMode?

    var body: some View {
        FilePairCompareView(
            left: pair.left, right: pair.right,
            title: pair.groupName,
            subtitle: kindPill,
            claimHeadline: ComparePairClaim.headline(
                kind: pair.matchType.kind,
                contentUnverified: pair.copies.contains(where: \.contentUnverified)),
            offersVerify: ComparePairClaim.offersVerify(kind: pair.matchType.kind),
            keeperPath: standing.keeperPath,
            // A stale surface still shows everything; only the acts stop. Folding staleness into
            // the keeper rule here keeps the viewer free of a concept only one host has.
            allowsKeeperChoice: allowsKeeperChoice && standing.offersVerdict,
            notice: notice,
            scanRoot: scanRoot, providerName: providerName, hue: hue,
            availableSize: availableSize,
            onChooseKeeper: onChooseKeeper,
            onClose: onClose,
            probe: probe, hash: hash, initialMode: initialMode,
            verdict: { verdictBar($0) })
    }

    /// The line above the facts: what is wrong with this pair's verdict, or nothing.
    ///
    /// Internal rather than private, as a seam, like ``trashTitle``: a button's enablement and a
    /// `Text`'s string can't be read back off a mounted view, so this and ``verdictSummary`` are how
    /// a test asserts that a surface whose group keeps a third copy withdraws its verdict and says
    /// why.
    ///
    /// Two different states. A stale surface shows last scan's facts, and the fix is to look again.
    /// A group keeping a third copy shows current facts with no keeper here to trash against, and
    /// "rescan" would send the reader to do something that changes nothing.
    var notice: String? {
        switch standing {
        case .inPair:
            return nil
        case .noLiveGroup:
            return "The scan moved on — the facts below are from the last scan, so the verdict is unavailable. Close and compare again."
        case .outsidePair(let name):
            return "This group is keeping “\(name)”, which is neither of these two — so neither copy here can be trashed against it. Compare either one against the copy being kept, or resolve the whole group."
        }
    }

    private var kindPill: String {
        switch pair.matchType {
        case .identical: return "byte-for-byte"
        case .sameText: return "bytes differ"
        case .versions: return "versions"
        case .overlapping(let f): return "\(Int((f * 100).rounded()))% shared"
        }
    }

    private var otherCopy: DuplicateCopy? { standing.keeperPath.flatMap { pair.other(than: $0) } }

    /// What the bar says beside the buttons: the facts summary where the verdict stands, a one-line
    /// reason where it doesn't, so the bar is never a row of disabled buttons with nothing saying
    /// why.
    func verdictSummary(_ facts: ComparePairFacts) -> String {
        switch standing {
        case .inPair: return facts.summary
        case .noLiveGroup: return "Rescan to act on this pair."
        case .outsidePair: return "The copy this group is keeping is not one of these two."
        }
    }

    private func verdictBar(_ facts: ComparePairFacts) -> some View {
        HStack(spacing: 10) {
            Text(verdictSummary(facts))
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            trashButton
            // ⏎ and esc both mean Done; the handlers live on the viewer's focused root. No
            // chord goes on the trash button.
            //
            // Prominent, so the safe act is the one the surface leads with, beside a destructive
            // one that is a plain bordered button. Never reverse the emphasis.
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .accentedProminent(hue)
                .controlSize(.regular)
                .shortcutKeycap("↩")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // A quiet ground under the bar that decides things, so it reads as the surface's footer
        // rather than one more row of content.
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private var trashButton: some View {
        let other = otherCopy
        let reason = other.flatMap {
            DuplicateComparePrompt.disabledReason(copyIsProtected: protectedPaths.contains($0.path),
                                                  copyName: $0.name)
        }
        Button(role: .destructive) {
            if let other, let keeper = standing.keeperPath.flatMap({ pair.copy(atPath: $0) }) {
                onTrash(other, keeper)
            }
        } label: {
            Label(trashTitle, systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!standing.offersVerdict || other == nil || reason != nil)
        .lockedDuringRun()
        .help(reason ?? "Move the other copy to the Trash")
    }

    /// Named for the copy it destroys, which follows the keeper flip; see
    /// ``DuplicateComparePrompt/trashTitle(kind:keeper:target:)``.
    ///
    /// Internal rather than private, as a seam. The wording rule is tested where it lives, but
    /// passing `keeper:` and `target:` the wrong way round would invert the label on every versions
    /// pair and still satisfy those tests. A SwiftUI button's title can't be read back off a mounted
    /// view (these styles bridge to `_NSGraphicsView`, with no `NSButton`), so the seam lets the
    /// call site be asserted. `SettingsRail.versionText` exists for the same reason.
    var trashTitle: String {
        DuplicateComparePrompt.trashTitle(kind: pair.matchType.kind,
                                          keeper: standing.keeperPath.flatMap { pair.copy(atPath: $0) },
                                          target: otherCopy)
    }
}

// MARK: - The host-side overlay

/// The Compare Copies surface as the window presents it: scrim, clamp, card treatment, and the one
/// place that re-derives the live grouping the sheet renders against.
///
/// Public, and the only public thing here, so `ContentView` mounts one view and knows nothing
/// about pair verdicts, keeper rules or stale scans. The sheet itself holds no manager reference:
/// every act leaves through a closure this wrapper supplies.
///
/// Everything is re-derived on every render, by path. `DuplicateGroup.id` doesn't survive a
/// rescan, so the keeper, the keeper-choice rule, the protected set and "has the scan moved on"
/// are read out of `duplicateGroups` at draw time, and a rescan under the open surface
/// re-validates it with no observer to wire or forget.
public struct CompareCopiesOverlay: View {

    @ObservedObject private var syncManager: FileSyncManager
    private let pair: DuplicateComparePair
    private let scanRoot: String?
    private let providerName: String?
    private let onClose: () -> Void
    private let confirmTrash: (DuplicateCopy, DuplicateCopy, String) -> Bool

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    /// `confirmTrash` is a seam, as `DuplicateReviewCoordinator.confirmTrashRightCopy` is:
    /// `NativeAlerts.confirmDestructive` is a blocking modal, so inlined, the one destructive path on
    /// this surface couldn't be driven by a test (the declined answer, the engine's refusals, the
    /// success that closes the overlay). Defaults to the real alert.
    ///
    /// It takes the copy, the keeper and the keeper's location rather than composing its own
    /// wording: the words come from ``DuplicateComparePrompt``, which is where they are tested.
    public init(syncManager: FileSyncManager, pair: DuplicateComparePair,
                scanRoot: String?, providerName: String?,
                onClose: @escaping () -> Void,
                confirmTrash: ((DuplicateCopy, DuplicateCopy, String) -> Bool)? = nil) {
        self.syncManager = syncManager
        self.pair = pair
        self.scanRoot = scanRoot
        self.providerName = providerName
        self.onClose = onClose
        let kind = pair.matchType.kind
        let crumbs: (String) -> String = { path in
            DuplicateGroupCard.crumbs(of: path, scanRoot: scanRoot, providerName: providerName)
                .dropLast().joined(separator: " › ")
        }
        self.confirmTrash = confirmTrash ?? { copy, keeper, keeperLocation in
            NativeAlerts.confirmDestructive(
                messageText: DuplicateComparePrompt.messageText(copyName: copy.name),
                informativeText: DuplicateComparePrompt.informativeText(
                    kind: kind,
                    copyName: copy.name, copyLocation: crumbs(copy.path),
                    keeperName: keeper.name, keeperLocation: keeperLocation,
                    reclaimText: FileSyncManager.formatBytes(copy.size)),
                confirmTitle: DuplicateComparePrompt.confirmTitle)
        }
    }

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    /// The group holding both paths right now, or nil once the scan has moved on.
    private var liveGroup: DuplicateGroup? {
        syncManager.liveGroup(holding: pair.right.path, and: pair.left.path)
    }

    /// Which copy the live group is keeping, as this pair can see it (see ``PairKeeperStanding``).
    /// The seam for the rule that decides whether the destructive verdict is offered at all: a
    /// pure function of a pair and a group, asserted as one, since `sheet(available:)` is private.
    static func keeperStanding(of pair: DuplicateComparePair,
                               in group: DuplicateGroup?) -> PairKeeperStanding {
        guard let group else { return .noLiveGroup }
        guard pair.copies.contains(where: { $0.path == group.keeper.path }) else {
            return .outsidePair(name: group.keeper.name)
        }
        return .inPair(group.keeper.path)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                OverlayScrim(level: glassLevel)
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
        return CompareCopiesSheet(
            pair: pair,
            standing: Self.keeperStanding(of: pair, in: group),
            allowsKeeperChoice: group?.allowsKeeperChoice ?? false,
            protectedPaths: Set((group?.copies ?? []).filter(\.isProtectedFromRemoval).map(\.path)),
            scanRoot: scanRoot,
            providerName: providerName,
            hue: glassHue,
            availableSize: available,
            onChooseKeeper: { path in
                // Looked up at click time, not captured: `setKeeper` takes a group id, and a rescan
                // may have replaced the one this surface opened over, making it a silent no-op.
                // With the live group, the flip lands on the current group or not at all.
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
    /// The confirmation is a deliberate click, never `⏎`, which belongs to Done. Its wording comes
    /// from ``DuplicateComparePrompt``, where it is tested, so it can't call an unproven copy
    /// "redundant" at the point of no return. Internal, not private, so the one destructive path on
    /// this surface is reachable from a test, as `confirmTrash` is.
    func trash(_ copy: DuplicateCopy, keeper: DuplicateCopy) {
        let keeperLocation = DuplicateGroupCard
            .crumbs(of: keeper.path, scanRoot: scanRoot, providerName: providerName)
            .dropLast().joined(separator: " › ")
        guard confirmTrash(copy, keeper, keeperLocation) else {
            Logger.shared.info("User declined trashing the compared copy \(copy.path)")
            return
        }
        Task { @MainActor in
            // The surface closes only on a removal that actually happened. A refusal (a drifted
            // copy, a moved keeper, a scan landing underneath) posts its banner and leaves the pair
            // up, where the user can see what it said and try again.
            if await syncManager.resolveDuplicateCopy(copy, keeper: keeper) { onClose() }
        }
    }
}

/// One side's keeper row in the Compare sheet's pane header.
struct CompareKeeperHeaderRow: View {
    let control: CompareKeeperControl
    let accessibilityLabel: String?
    let accent: Color
    let onKeepInstead: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch control {
            case .keeping:
                // A state, drawn as a state: the kept side is not a control (clicking it does
                // nothing), so it wears a filled chip rather than a disabled button.
                keepingChip
                    .accessibilityLabel(accessibilityLabel ?? "Kept copy")
            case .keepInstead:
                Button(action: onKeepInstead) {
                    Label("Keep This Instead", systemImage: "circle")
                        .scaledFont(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(accessibilityLabel ?? "Keep this copy")
                .help(ShortcutHint.tooltip("Keep this copy instead", "←→"))
            case .nothing:
                // An overlap group: it has a keeper, but no choice (see `CompareKeeperControl`).
                // The chip's height, drawn invisibly, so this preview lines up with the kept side's
                // under its "Keeping this" chip.
                keepingChip
                    .hidden()
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 2)
    }

    private var keepingChip: some View {
        Label("Keeping this", systemImage: "checkmark.circle.fill")
            .scaledFont(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background { Capsule().fill(accent.opacity(0.13)) }
    }
}

/// What the Compare sheet's pane header offers on one side of a group that has a keeper.
///
/// A keeper is not the same as a choice. An overlap group has a keeper (the copy holding what
/// the others lack) but can't re-aim it, because which copy is "unique" comes from content hashes
/// the scan doesn't retain (`DuplicateKeeperMarker.style`). A disabled "Keep this instead" would
/// advertise a choice that doesn't exist, so that side draws nothing, in the chip's height so the
/// two previews still line up (see `CompareKeeperHeaderRow`).
enum CompareKeeperControl: Equatable {
    /// The kept side: a chip, never a control.
    case keeping
    /// The other side of a group whose keeper can be changed.
    case keepInstead
    /// The other side of a group whose keeper cannot be changed.
    case nothing

    static func control(isKeeper: Bool, marker: DuplicateKeeperMarker) -> CompareKeeperControl {
        if isKeeper { return .keeping }
        return marker == .selectable ? .keepInstead : .nothing
    }
}
