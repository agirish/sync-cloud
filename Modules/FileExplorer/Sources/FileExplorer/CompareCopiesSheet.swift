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
public struct DuplicateComparePair: Identifiable, Equatable, Sendable {
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

    static var minimum: CGSize { CGSize(width: minimumWidth, height: minimumHeight) }

    /// The remembered size. **Two keys rather than one archived `CGSize`**, the reason the Help
    /// card gives: a width that survives a height's decoding failure is strictly better than
    /// losing both, and `@AppStorage` reads `Double` natively. `0` means "never resized" — the
    /// default below is then whatever the window can give.
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
    /// **A stored size is clamped on every render, not only when it is written.** The window can
    /// shrink between sessions — or between two launches on different displays — and a card that
    /// trusted what it stored would open wider than the window it is in, with its verdict bar off
    /// screen and no way to reach the grip that would fix it.
    static func size(available: CGSize, stored: CGSize?) -> CGSize {
        guard let stored, stored.width > 0, stored.height > 0 else { return size(available: available) }
        return ResizableCardSize.clamped(stored, minimum: minimum, within: available)
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
struct FilePairCompareView<Verdict: View>: View {

    let left: DuplicateCopy
    let right: DuplicateCopy
    /// What the surface is comparing — a duplicate group's name, or a relative path.
    let title: String
    /// The line under it: a match kind, or which two roots the pair came from.
    let subtitle: String
    /// The claim the pair's origin makes about its content, or nil where it makes none. The
    /// Differences host makes none: two files at one relative path on two roots are not asserted
    /// to be anything.
    let claimHeadline: String?
    /// Whether "Verify now" is offered — only where a byte-identical claim exists to re-check.
    let offersVerify: Bool
    /// The path of the copy currently being kept, or nil where there is no keeper concept at all.
    /// The Differences host passes nil and its pane headers are labels rather than pickers.
    let keeperPath: String?
    /// Whether the keeper may be changed. Read off the live group rather than assumed, so the
    /// surface and the card cannot drift.
    let allowsKeeperChoice: Bool
    /// A line the host wants above the facts — the duplicates host's "the scan moved on" notice.
    let notice: String?
    let scanRoot: String?
    let providerName: String?
    /// The window's hue, not a resolved `Color`. The segmented mode picker needs the hue itself —
    /// `.accentedSegments` takes one, and handing it a literal is the bug that modifier exists to
    /// prevent — so the surface carries the hue and resolves the accent from it, rather than
    /// carrying both and letting them disagree.
    let hue: LiquidGlassHue
    let availableSize: CGSize

    var onChooseKeeper: (String) -> Void = { _ in }
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
    /// The mode to open in. nil — every production caller — means side by side.
    ///
    /// A seam for one property: a pixel mode entered BEFORE the sides have been classified must
    /// still get them classified. Pressing `4` on a freshly-opened surface is exactly that, and
    /// there is no way to post a key into a `@State` mode from a test.
    var initialMode: ComparePairMode?

    /// **The only thing the two hosts do not share.** Everything above this bar is one component:
    /// the facts, the panes, the modes, the strip. Only the bottom bar knows WHY you are looking —
    /// Duplicates offers a keeper and a trash, Differences offers Done. Which is exactly what
    /// ROADMAP §11 asked for and why it is one build rather than two.
    @ViewBuilder var verdict: () -> Verdict

    @State private var sources: [String: ColumnPreviewSource] = [:]
    @State private var verify: ComparePairVerify = .idle
    @State private var mode: ComparePairMode = .sideBySide
    @State private var page = 0
    /// nil until the page counts have been asked for.
    ///
    /// **"Not asked yet" and "opens to nothing" are different**, and a plain `PagePairing(0, 0)`
    /// said both. A PDF pair fell through to the Quick Look panes while the count was in flight
    /// and swapped to the typed viewer when it landed — a visible flicker, and a Quick Look
    /// extension process spun up for a preview that was about to be replaced.
    @State private var pairing: PagePairing?
    @State private var rasters: (left: CGImage?, right: CGImage?) = (nil, nil)
    @State private var difference: CGImage?
    @State private var pageStates: [Int: PageDiffState] = [:]
    @State private var swipeFraction: Double = 0.5
    @State private var onionOpacity: Double = 0.5
    /// ⌥ held: the two viewers stop mirroring each other so one pane can be moved on its own.
    @State private var optionHeld = false
    /// Guards a raster that arrives after the user has paged on — the same token shape the verify
    /// uses, for the same reason.
    @State private var rasterToken = UUID()
    /// Whether the current page's rasters are still coming or are never going to. A pane with no
    /// image and no answer here spins for the life of the surface — see ``PairRenderOutcome``.
    @State private var renderOutcome: PairRenderOutcome = .rendering
    @State private var textDiff: TextPairDiff?
    @State private var textNotes: [String] = []
    /// Guards a diff that lands after the pair moved on — the raster path's token, for a race the
    /// text path is MORE exposed to: two detached Myers passes have no ordering between them, so a
    /// slow pair's diff can resume after a fast pair's has already been drawn.
    @State private var textDiffToken = UUID()
    /// Which change ↑/↓ last stepped to, or nil while nothing has been stepped to yet.
    ///
    /// **Optional rather than 0, because "the first change" and "no change chosen" are different
    /// states.** Starting at 0 made the first ↓ compute 0+1 and skip to the second change — the
    /// first was then reachable only by wrapping all the way round — and the counter read "1 of N"
    /// about a region nothing had scrolled to.
    @State private var focusedRegion: Int?
    /// Guards a completion from a verify the user has already superseded — the same token shape
    /// `ReviewCardView.performVerify` uses.
    @State private var verifyToken = UUID()
    @StateObject private var downloads = PaneDownloadWatch()
    @FocusState private var focused: Bool

    @AppStorage(CompareOverlayMetrics.widthDefaultsKey) private var storedWidth: Double = 0
    @AppStorage(CompareOverlayMetrics.heightDefaultsKey) private var storedHeight: Double = 0
    /// The live size WHILE a grip is held. Separate from the stored one so a drag redraws without
    /// writing to defaults on every frame — the size is committed once, on release.
    @State private var dragging: CGSize?

    private var accent: Color { hue.accentColor }

    /// What every `.task(id:)` here is keyed on. The two paths, sorted — so opening the same pair
    /// from either side re-uses the work rather than redoing it.
    private var pairKey: String { [left.path, right.path].sorted().joined(separator: "\n") }

    /// The size a drag measures FROM — the committed one, never the live one.
    ///
    /// **Always the committed size, so the drag needs no starting size captured.** Resolving each
    /// frame against the previous frame's result compounds: the doubling in
    /// `ResizableCardSize.resized` would be applied again to an already-grown size and the card
    /// would run away from the pointer.
    private var committedSize: CGSize {
        CompareOverlayMetrics.size(available: availableSize,
                                   stored: CGSize(width: storedWidth, height: storedHeight))
    }

    /// The size the card draws at — a live drag, else the committed one.
    private var size: CGSize { dragging ?? committedSize }

    private var facts: ComparePairFacts {
        ComparePairFacts.make(left: left, right: right,
                              scanRoot: scanRoot, providerName: providerName)
    }

    /// The pair's viewer kind. **Both sides must agree, or the pair is `.other`** — a versions
    /// group can hold `Report.pdf` beside `Report.docx`, and a PDF viewer given a Word document
    /// shows a blank pane rather than saying it cannot page it.
    private var kind: PairContentKind {
        let leftKind = PairContentKind.classify(path: left.path)
        return leftKind == PairContentKind.classify(path: right.path) ? leftKind : .other
    }

    private var modes: [ComparePairMode] { ComparePairMode.available(for: kind) }

    /// The mode to DRAW in — the chosen one, unless this pair does not offer it.
    ///
    /// **A kind change can strand the mode.** `mode` is `@State` and the offered set comes from
    /// the pair's kind, so a surface handed a PDF pair while sitting in `.textDiff` would render
    /// the previous pair's line diff under a segmented control with nothing selected. Clamped
    /// here rather than only reset on the pair task, so the render can never disagree with the
    /// picker even for the frame between the two.
    private var activeMode: ComparePairMode { modes.contains(mode) ? mode : .sideBySide }

    /// The page pairing, or an empty one while the counts are still being asked for. Callers that
    /// need to know the difference read `pairing` itself.
    private var resolvedPairing: PagePairing { pairing ?? PagePairing(leftPages: 0, rightPages: 0) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice { noticeBar(notice) }
            claimAndFacts
            Divider()
            if modes.count > 1 { modeBar }
            panes
            if kind == .pdf, resolvedPairing.stripLength > 1 {
                Divider()
                PageStrip(pairing: resolvedPairing, states: pageStates, current: page,
                          accent: accent) { page = $0 }
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            verdict()
        }
        .frame(width: size.width, height: size.height)
        // **`.focusable()` is what makes the keys below work, and `.focusEffectDisabled()` is what
        // stops it painting.** Without it macOS draws the standard focus ring — a hard accent
        // rectangle around the WHOLE card, which reads as a stray highlight rather than as focus,
        // because nothing about this surface looks like a control. The keys still arrive: the ring
        // is the effect, not the focus.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            if let initialMode { mode = initialMode }
        }
        // **Both sides are classified at the ROOT, not inside a pane.** The probe used to live in
        // the per-side preview, which only the side-by-side fallback mounts — so opening the
        // surface and pressing `4` straight away left `sources` empty for ever: the raster refresh
        // bailed on "not both readable" and nothing could re-trigger it, because the thing that
        // would have was in a branch that mode never renders. A permanent spinner.
        //
        // Keyed on the path AND the download latch, so a cloud-only side that lands re-probes —
        // which is what turns its placeholder into a preview without a second poller.
        .task(id: probeKey(left)) { sources[left.path] = await probe(left.path) }
        .task(id: probeKey(right)) { sources[right.path] = await probe(right.path) }
        // Drag any edge or corner to resize, and the size is remembered. `ResizableCardGrips` is
        // the Help card's own apparatus, moved to `Design` when this became the second resizable
        // overlay rather than copied.
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
        // Plain keys anchored on the surface's focused root. **The `keys:` overload, because it
        // is the one that hands the handler a `KeyPress`** — `.onKeyPress(_:action:)` does not, so
        // a handler written that way cannot tell a bare ← from ⌘←, and `.onKeyPress` is measured
        // to deliver MODIFIED presses to its handlers. `isPlainKeystroke` rather than
        // `modifiers.isEmpty`, per the house rule: Caps Lock alone arrives as a modifier and would
        // kill both keys.
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.isPlainKeystroke else { return .ignored }
            return chooseKeeper(press.key == .leftArrow ? left : right)
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
        // `keys:` rather than the single-key overload, because that one does NOT filter modifiers
        // either — the same measured fact the ⏎ handler above is written around. This file's rule
        // is `isPlainKeystroke` on every handler, and esc was the one that did not follow it.
        .onKeyPress(keys: [.escape], phases: .down) { press in
            guard press.isPlainKeystroke else { return .ignored }
            onClose()
            return .handled
        }
        // 1–4 pick a mode by its position in what this pair OFFERS — see
        // `ComparePairMode.forDigit(_:in:)`. A text pair offers two segments, so `2` there is its
        // Diff; a digit past the end is `.ignored` rather than reaching a segment not on screen.
        .onKeyPress(keys: ["1", "2", "3", "4"], phases: .down) { press in
            guard press.isPlainKeystroke,
                  let digit = Int(String(press.key.character)),
                  let picked = ComparePairMode.forDigit(digit, in: modes) else { return .ignored }
            mode = picked
            return .handled
        }
        // ⇞/⇟ page BOTH sides — the surface owns the page, so there is one number and the
        // pairing clamps each side to its own last page.
        .onKeyPress(keys: [.pageUp, .pageDown], phases: .down) { press in
            guard press.isPlainKeystroke, resolvedPairing.stripLength > 1 else { return .ignored }
            let next = press.key == .pageUp ? page - 1 : page + 1
            page = min(max(0, next), resolvedPairing.stripLength - 1)
            return .handled
        }
        // ⌥ as a HELD modifier, not a chord: chords with ⌥ are banned app-wide (they fire from
        // inside the ⌥-hold keycap reveal), and this is the modifier's other meaning — while it is
        // down the two viewers stop mirroring, so one pane can be moved on its own.
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
        // The page count each side actually has, which is what the strip and the pairing are
        // built from. Off the main actor and behind the serial lane, so a scan already parsing
        // simply makes it arrive late.
        .task(id: pairKey) {
            // **A fresh pair inherits nothing.** Every one of these is `@State` on a view the host
            // can hand a new pair without unmounting, and each carries an answer about the
            // PREVIOUS pair: a strip of dots, a line diff, a verify verdict, a page number, and a
            // mode this pair may not even offer. The reset used to cover only the first of them,
            // and only for PDFs — it sat below the `kind` guard.
            pageStates = [:]
            page = 0
            textDiff = nil
            textNotes = []
            focusedRegion = nil
            verify = .idle
            rasters = (nil, nil)
            difference = nil
            renderOutcome = .rendering
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
        // Cancelled by `.task(id:)` when the page changes, which is what stops a 300-page document
        // from queueing 300 renders behind a scan.
        .task(id: rasterKey) { await refreshRasters() }
        // Re-read only when the pair changes or the diff is actually being looked at — a text
        // pair the user never switches to Diff costs nothing.
        .task(id: "\(pairKey)|\(activeMode.rawValue)") { await refreshTextDiff() }
        // ↑/↓ step between CHANGES, not lines: a twelve-line replacement is one thing that
        // happened, and twelve presses to get past it is twelve too many.
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            guard press.isPlainKeystroke, activeMode == .textDiff,
                  let diff = textDiff, !diff.regions.isEmpty else { return .ignored }
            focusedRegion = TextPairDiff.steppedRegion(from: focusedRegion,
                                                       direction: press.key == .upArrow ? -1 : 1,
                                                       count: diff.regions.count)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare \(title)")
    }

    // MARK: Header

    /// Glyph, name, and the kind as a PILL beside it rather than grey text beneath.
    ///
    /// **The card states the kind as a pill and so does this.** Stacked under the title it read as
    /// a subtitle — a property of the sentence above it — where it is really a claim about the
    /// pair, and the one the whole surface is arguing about. On one line with the name it is the
    /// same badge the group card wears, which is where the reader met it.
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

    /// A line the host wants above the facts. Today that is the duplicates host saying a rescan
    /// landed under the open surface — the previews are still worth reading and only the verdict
    /// has to stop, so the surface says so rather than being torn down under the user.
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
    private var claimAndFacts: some View {
        VStack(alignment: .leading, spacing: 8) {
            // **Verify sits beside the claim it re-checks, not at the far edge.** Pushed right by
            // a `Spacer` it was a control floating alone 900pt from the sentence that gives it
            // meaning; the eye had no reason to connect them.
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

    /// The facts, as two blocks — one over each pane.
    ///
    /// **The whole card is two columns, and this is the top of them.** A single table with the
    /// labels in a left gutter pushed both value columns right by the gutter's width, so neither
    /// sat over the pane it describes; a centre spine fixed the alignment and broke the reading,
    /// because right-aligning the left column drags long paths into the middle and leaves the
    /// pane's own half empty. Two self-contained blocks put each side's facts, its keeper control
    /// and its preview in one column from top to bottom, which is the structure the reader is
    /// already using.
    ///
    /// The labels repeat, and that is the cost. At 9pt tertiary they are a gutter rather than
    /// content, and what is bought is that a value never sits over the wrong pane.
    private var factsGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            factsBlock(\.left)
            factsBlock(\.right)
        }
    }

    private func factsBlock(_ side: KeyPath<ComparePairFacts.Row, String>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(facts.rows) { row in
                GridRow {
                    Text(row.label.uppercased())
                        .scaledFont(.system(size: 9, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)
                    factValue(row[keyPath: side], differs: row.differs,
                              // **A path truncates from the HEAD.** Middle-truncation ate the one
                              // part of a breadcrumb that distinguishes two copies — the deepest
                              // folders — and left the provider name both sides share. A name
                              // truncates in the middle, where the extension and any "(1)" live.
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
            .accessibilityLabel("Compare mode")
            if activeMode == .onion {
                Slider(value: $onionOpacity, in: 0...1)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Onion blend")
            }
            if let caveat = activeMode.caveat {
                Text(caveat)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // Only where a raster answered AND the sizes actually differ: a caveat printed while
            // the render is pending would be describing the previous page, and an empty one would
            // reserve space for a sentence that is not there.
            if !sizeCaveat.isEmpty, pageStates[page]?.isResolved == true {
                Text(sizeCaveat)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                                   difference: difference,
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

    /// The line diff, or the reason there is none. **A refusal names WHICH side and why** —
    /// too large, not downloaded, not text — rather than an empty pane the reader has to guess at.
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

    /// Reads both sides and diffs them, off the main actor.
    ///
    /// Bounded and encoding-tolerant — see ``BoundedTextRead``. The diff itself is a Myers pass
    /// over two line arrays, which for a 4 MB file is real work and has no business on the actor
    /// that draws the window.
    ///
    /// **Token-guarded, like the raster path.** `.task(id:)` cancels the task that awaits, but a
    /// `Task.detached` neither observes that cancellation nor finishes in the order it was
    /// started: a large pair's diff can resume after a small pair's has been drawn and overwrite
    /// it, leaving one pair's changes under another pair's name until the mode is left and
    /// re-entered. The token is taken before the hop and re-read after it.
    private func refreshTextDiff() async {
        let token = UUID()
        textDiffToken = token
        guard kind == .text, activeMode == .textDiff else {
            // Cleared, not merely skipped: a diff left standing here is the PREVIOUS pair's, and
            // `textDiffPane` renders whatever is in it the moment the mode comes back. The focus
            // goes with it — a position into regions that no longer exist.
            textDiff = nil
            textNotes = []
            focusedRegion = nil
            return
        }
        let leftPath = left.path, rightPath = right.path
        let result = await Task.detached(priority: .userInitiated) {
            () -> (TextPairDiff?, [String]) in
            let left = BoundedTextRead.read(path: leftPath)
            let right = BoundedTextRead.read(path: rightPath)
            var notes: [String] = []
            guard let leftText = left.string, let rightText = right.string else {
                if let caption = left.caption { notes.append("Left: \(caption)") }
                if let caption = right.caption { notes.append("Right: \(caption)") }
                return (nil, notes)
            }
            if case .text(_, lossy: true) = left {
                notes.append("The left file is not valid UTF-8 — unreadable bytes are shown as “\u{FFFD}”.")
            }
            if case .text(_, lossy: true) = right {
                notes.append("The right file is not valid UTF-8 — unreadable bytes are shown as “\u{FFFD}”.")
            }
            if let note = BoundedTextRead.lineEndingNote(left: leftText, right: rightText) {
                notes.append(note)
            }
            return (TextPairDiff.make(left: BoundedTextRead.lines(leftText),
                                      right: BoundedTextRead.lines(rightText)), notes)
        }.value
        guard textDiffToken == token else { return }
        textDiff = result.0
        textNotes = result.1
        focusedRegion = nil
    }

    /// Whether both documents actually opened. **A page count of zero is a document that would not
    /// open** — encrypted, truncated, or not really a PDF — and the pairing's `stripLength` cannot
    /// say so, because it is the longer of the two: one side at 0 against a healthy 6 still reads
    /// as 6, and the typed viewer then mounted a pane that could only ever be grey.
    private var bothSidesOpened: Bool {
        resolvedPairing.leftPages > 0 && resolvedPairing.rightPages > 0
    }

    /// The line explaining why a pair that should have earned a typed viewer is showing plain
    /// previews instead, or nil when nothing is wrong. Named per side, because the reader is
    /// looking at two similarly named files and needs to know which one is the problem.
    private var unopenableCaption: String? {
        guard bothSidesReadable else { return nil }
        switch kind {
        case .pdf:
            // Reached only once the page counts have landed: while they are in flight the surface
            // is showing a spinner from `stillResolvingTypedViewer` and never renders this branch.
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
    /// **A typed viewer replaces the Quick Look panes only where it is genuinely better.** For a
    /// cloud-only or missing side there is nothing to open, so the pair falls back to the per-side
    /// panes that can say why — a `PDFView` given a placeholder path shows an empty grey box.
    @ViewBuilder
    private var sideBySidePanes: some View {
        if kind.hasSyncedViewer && stillResolvingTypedViewer {
            // **Neither panes nor a decision yet.** A kind that is about to get a typed viewer
            // must not flash the Quick Look fallback first: that swaps the whole pane a moment
            // later, and spins up a Quick Look extension process for a preview already on its way
            // out. `pairing == nil` is what distinguishes "the count is in flight" from "this PDF
            // opens to nothing", which is why it is optional.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .pdf, bothSidesReadable, bothSidesOpened {
            typedPanes {
                PDFPairView(leftPath: left.path, rightPath: right.path,
                            page: page, pairing: resolvedPairing, syncSuspended: optionHeld)
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
                // **Why these are plain previews and not the typed viewer.** Falling back without
                // saying so leaves the reader with a surface that is quietly less than it was for
                // the pair beside it, and no idea which copy is the reason.
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

    /// Both sides have content on disk. A typed viewer has no way to say "this one is a cloud
    /// placeholder"; the per-side Quick Look panes do, and that is what they fall back to.
    private var bothSidesReadable: Bool {
        sources[left.path] == .quickLook && sources[right.path] == .quickLook
    }

    /// Whether a kind that earns a typed viewer is still waiting on the facts that decide it —
    /// either side unclassified, or (for a PDF) the page counts not yet asked for.
    private var stillResolvingTypedViewer: Bool {
        if sources[left.path] == nil || sources[right.path] == nil { return true }
        return kind == .pdf && pairing == nil
    }

    // MARK: Rasters

    /// What a render is keyed on. The mode is in it because side-by-side on a PDF needs no raster
    /// at all — the two `PDFView`s draw themselves — so switching INTO a pixel mode is what starts
    /// the work, and switching out stops re-doing it.
    /// **`bothSidesReadable` is in the key, and that is the other half of the probe fix.** The
    /// refresh bails when the sides are not yet classified; without that term nothing re-keys the
    /// task when they are, so the bail was permanent.
    private var rasterKey: String {
        "\(pairKey)|\(page)|\(kind.rawValue)|\(needsRasters)|\(showsOverlayModes)"
            + "|\(bothSidesReadable)|\(resolvedPairing.stripLength)"
    }

    /// Whether the DIFF is being looked at, as opposed to the rasters merely being needed.
    ///
    /// An image pair needs its rasters in every mode — `ImagePairView` draws them — but the
    /// difference image is a third full-size raster and the comparison a pass over two more, and
    /// side by side shows neither. Computing them anyway would spend that on every image pair
    /// opened, for a number nobody is reading.
    private var showsOverlayModes: Bool { activeMode != .sideBySide }

    private var needsRasters: Bool {
        kind.hasPixelModes && (activeMode != .sideBySide || kind == .image)
    }

    /// Renders both sides of the current page and diffs them.
    ///
    /// **The lane is held for open and draw only.** `PagePairRaster` releases it before returning,
    /// and the diff — plain arithmetic over two buffers, not PDFKit — runs off it. Holding the
    /// lane across the pixel work would stall a running scan's extractions behind a compare.
    private func refreshRasters() async {
        guard needsRasters, bothSidesReadable else {
            rasters = (nil, nil)
            difference = nil
            // No answer rather than a verdict: nothing was asked of the renderer here, and a
            // `.failed` left standing from a previous page would caption a pane that is merely
            // waiting for its first render.
            renderOutcome = .rendering
            return
        }
        let token = UUID()
        rasterToken = token
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
        // A raster that lands after the user has paged on describes a page nobody is looking at.
        guard rasterToken == token else { return }
        rasters = (l?.cgImage, r?.cgImage)
        guard let l, let r else {
            difference = nil
            pageStates[page] = .unrenderable
            // **The same finding the strip just recorded, told to the panes.** They knew only that
            // they had no image, which is what a render still in flight looks like too.
            renderOutcome = .failed(left: l == nil, right: r == nil)
            return
        }
        renderOutcome = .ready
        guard showsOverlayModes else {
            // The rasters are up (the image viewer draws them); nothing here is being compared.
            difference = nil
            return
        }
        // Off the main actor: this is the buffer loop, and on a 1600px page it is milliseconds of
        // arithmetic that has no business on the actor that draws the window.
        let comparison = await Task.detached(priority: .utility) { () -> (SendableImage?, BitmapDiffResult?) in
            (BitmapDiff.differenceImage(l.cgImage, r.cgImage).map(SendableImage.init),
             BitmapDiff.compare(l.cgImage, r.cgImage))
        }.value
        guard rasterToken == token else { return }
        difference = comparison.0?.cgImage
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

    /// **A keeper picker only where there is a keeper to pick.** With `keeperPath` nil — the
    /// Differences host, where two files at one relative path on two roots are not a group and
    /// nothing is being kept — the header is the file's name and nothing else. It used to render
    /// two disabled "Keep this" buttons there, which advertises a choice that does not exist: the
    /// exact complaint that produced `DuplicateKeeperMarker` ("Why is there a checkbox, especially
    /// if we can't choose among the rows?"), reached through a new door.
    @ViewBuilder
    private func paneHeader(_ copy: DuplicateCopy) -> some View {
        if let keeperPath {
            let isKeeper = copy.path == keeperPath
            let marker = DuplicateKeeperMarker.style(allowsKeeperChoice: allowsKeeperChoice,
                                                     isKeeper: isKeeper)
            // **The keeper control, and nothing else.** The file's name used to sit at the far
            // end of this row — the same string the NAME fact states directly above it, on a
            // surface whose whole complaint was clutter. One statement per fact.
            HStack(spacing: 6) {
                if isKeeper {
                    // A state, drawn as a state: the kept side is not a control (clicking it does
                    // nothing), so it wears a filled chip rather than a disabled button.
                    Label("Keeping this", systemImage: "checkmark.circle.fill")
                        .scaledFont(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background { Capsule().fill(accent.opacity(0.13)) }
                        .accessibilityLabel(marker.accessibilityLabel ?? "Kept copy")
                } else {
                    Button { chooseKeeper(copy) } label: {
                        Label("Keep this instead", systemImage: "circle")
                            .scaledFont(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(marker == .inert)
                    .accessibilityLabel(marker.accessibilityLabel ?? "Copy")
                    .help(ShortcutHint.tooltip("Keep this copy instead", "←→"))
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 2)
        }
        // With no keeper — the Differences host — the row collapses entirely. The facts block
        // above already names and locates each side, and an empty header row is furniture.
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

    // MARK: Actions

    /// The one keeper flip, for the pane button and for ←/→ alike. Returns `.ignored` when there
    /// is nothing to flip, so an arrow key over a stale surface falls through to whatever else
    /// might want it rather than being swallowed.
    @discardableResult
    private func chooseKeeper(_ copy: DuplicateCopy) -> KeyPress.Result {
        guard allowsKeeperChoice, keeperPath != nil, copy.path != keeperPath else { return .ignored }
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
        let leftPath = left.path
        let rightPath = right.path
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

// MARK: - The Duplicates host's sheet

/// ``FilePairCompareView`` with the Duplicates verdict bar under it: a keeper, a single-copy
/// trash, and Done.
///
/// **Everything above that bar is the shared component**, and this wrapper is what the seam is
/// worth: it maps a duplicate group's vocabulary — match kind, keeper, protected copies, a stale
/// scan — onto a viewer that knows none of it.
struct CompareCopiesSheet: View {

    let pair: DuplicateComparePair
    /// The path of the copy currently being kept, read from the LIVE group by the host.
    let keeperPath: String
    let allowsKeeperChoice: Bool
    /// Copies that may never be removed — inside a folder another group is keeping.
    let protectedPaths: Set<String>
    /// True when no live group holds both paths any more.
    let isStale: Bool
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
    /// Forwarded to ``FilePairCompareView/initialMode`` — tests only; see there.
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
            keeperPath: keeperPath,
            // A stale surface still shows everything; only the ACTS stop. Folding staleness into
            // the keeper rule here rather than inside the viewer keeps the viewer free of a
            // concept only one host has.
            allowsKeeperChoice: allowsKeeperChoice && !isStale,
            notice: isStale
                ? "The scan moved on — the facts below are from the last scan, so the verdict is unavailable. Close and compare again."
                : nil,
            scanRoot: scanRoot, providerName: providerName, hue: hue,
            availableSize: availableSize,
            onChooseKeeper: onChooseKeeper,
            onClose: onClose,
            probe: probe, hash: hash, initialMode: initialMode,
            verdict: { verdictBar })
    }

    private var kindPill: String {
        switch pair.matchType {
        case .identical: return "byte-for-byte"
        case .sameText: return "bytes differ"
        case .versions: return "versions"
        case .overlapping(let f): return "\(Int((f * 100).rounded()))% shared"
        }
    }

    private var facts: ComparePairFacts {
        ComparePairFacts.make(left: pair.left, right: pair.right,
                              scanRoot: scanRoot, providerName: providerName)
    }

    private var otherCopy: DuplicateCopy? { pair.other(than: keeperPath) }

    private var verdictBar: some View {
        HStack(spacing: 10) {
            Text(isStale ? "Rescan to act on this pair."
                         : ComparePairFacts.summary(differing: facts.differingFields))
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            trashButton
            // **⏎ AND esc both mean Done** — the handlers live on the viewer's focused root. An
            // earlier draft of this surface put ⌘⏎ on the trash button.
            //
            // Prominent, and that is the house rule made visible: the SAFE act is the one the
            // surface leads with, standing beside a destructive one that is a plain bordered
            // button. Reversing the emphasis would be the ⌘⏎-to-trash mistake in paint.
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(hue.accentColor)
                .controlSize(.regular)
                .shortcutKeycap("⏎")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // A quiet ground under the bar that decides things, so it reads as the surface's footer
        // rather than as one more row of content.
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
            if let other, let keeper = pair.copy(atPath: keeperPath) { onTrash(other, keeper) }
        } label: {
            Label(trashTitle, systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isStale || other == nil || reason != nil)
        .help(reason ?? "Move the other copy to the Trash")
    }

    /// Named for the copy it destroys, which follows the keeper flip — see
    /// ``DuplicateComparePrompt/trashTitle(kind:keeper:target:)``.
    ///
    /// **Internal rather than private, as a seam.** The wording rule is unit-tested where it lives,
    /// but the rule is only half the defect: handing it `keeper:` and `target:` the wrong way round
    /// would invert the label on every versions pair and satisfy every test of the rule itself. A
    /// SwiftUI button's title cannot be read back off a mounted view — these styles bridge to
    /// `_NSGraphicsView`, with no `NSButton` and no title to walk to — so the seam is what lets the
    /// CALL SITE be asserted at all. `SettingsRail.versionText` exists for the same reason.
    var trashTitle: String {
        DuplicateComparePrompt.trashTitle(kind: pair.matchType.kind,
                                          keeper: pair.copy(atPath: keeperPath),
                                          target: otherCopy)
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
    private let confirmTrash: (DuplicateCopy, DuplicateCopy, String) -> Bool

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    /// `confirmTrash` is a seam for the reason `DuplicateReviewCoordinator.confirmTrashRightCopy`
    /// is one: `NativeAlerts.confirmDestructive` is a BLOCKING modal, so with the call inlined the
    /// one destructive path on this surface could not be driven by a test at all — not the
    /// declined answer, not the engine's refusals, not the success that closes the overlay.
    /// Defaults to the real alert, so production behaviour is unchanged.
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
            hue: glassHue,
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
    /// Internal, not private, so the ONE destructive path on this surface is reachable from a
    /// test at all — the same reason `confirmTrash` is a seam.
    func trash(_ copy: DuplicateCopy, keeper: DuplicateCopy) {
        let keeperLocation = DuplicateGroupCard
            .crumbs(of: keeper.path, scanRoot: scanRoot, providerName: providerName)
            .dropLast().joined(separator: " › ")
        guard confirmTrash(copy, keeper, keeperLocation) else {
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
