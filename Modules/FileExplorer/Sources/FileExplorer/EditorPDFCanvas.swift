import AppKit
import PDFKit
import SwiftUI
import Design

/// **The rules every piece floating over the PDF canvas keeps** (Phase 6a) — the page and zoom
/// capsule, the find card, and Fill & Sign's palette and save pill (6b). Written once, here, so
/// the pieces cannot each grow their own idea of where the edge is or what "in the way" means.
enum EditorPDFFloating {
    /// How far a floating piece stands in from the canvas's edges.
    static let inset: CGFloat = 14
    /// The least room between two floating pieces, and between the capsule and the page band it
    /// keeps clear.
    static let gap: CGFloat = 8
    /// The room above the first page when nothing floats at the top (mockup C).
    static let topBand: CGFloat = 28

    /// **At Clear, the floating pieces wear Frosted's glass.** Clear glass is drawn for chrome over
    /// the desktop; these sit over page text, and black type read through clear glass fights the
    /// capsule's own labels. One switch, so a change of mind is one line.
    static let clearDrawsFrosted = true

    /// The appearance a floating piece draws in, given the window's.
    static func appearance(_ window: SelectionLensAppearance) -> SelectionLensAppearance {
        guard clearDrawsFrosted, window.level == .clear else { return window }
        var floating = window
        floating.level = .frosted
        return floating
    }

    /// **In dark mode the glass stands on a dark veil** — the window's own background at this
    /// opacity, under the glass. Measured 2026-10-18 over a full page of black text: Frosted in dark
    /// left light labels on translucent grey with the type showing through; light mode reads, and
    /// keeps its glass bare. Under the glass, not on it, so the glass keeps its edge and sheen and
    /// only stops refracting the page. Chosen over Solid's ground at every level, 2026-10-18.
    /// Measured the same day: 0.85 still let the type through; 0.95 leaves a flat ground.
    static let darkVeil: Double = 0.95

    /// The veil's opacity for a piece drawn in `material` — ``darkVeil`` under glass in dark mode,
    /// none otherwise: Solid and Reduce Transparency draw an opaque ground already.
    static func veil(material: SelectionLensMaterial, colorScheme: ColorScheme) -> Double {
        guard colorScheme == .dark else { return 0 }
        switch material {
        case .frosted, .clear: return darkVeil
        case .today, .probe: return 0
        }
    }

    /// **Floating pieces never overlap.** `frame` slid along `axis` — the edge it is docked to —
    /// until it clears every one of `obstacles` by ``gap``, staying inside the canvas's inset; the
    /// nearer way wins. Only where no place along that edge is clear does it step across the edge
    /// instead, below or beside the obstacle, and then along both at once. `frame` itself when
    /// nothing is in the way, so the piece goes back the moment the other one closes.
    static func clear(_ frame: CGRect, of obstacles: [CGRect], sliding axis: Axis, within canvas: CGSize) -> CGRect {
        let blockers = obstacles.filter { !$0.isEmpty }
        // Half a point short of the gap, so a piece placed exactly a gap away reads as clear.
        func collides(_ rect: CGRect) -> Bool {
            blockers.contains { $0.insetBy(dx: -(gap - 0.5), dy: -(gap - 0.5)).intersects(rect) }
        }
        guard collides(frame) else { return frame }
        let room = CGRect(origin: .zero, size: canvas).insetBy(dx: inset - 0.5, dy: inset - 0.5)
        func candidates(_ axis: Axis) -> [CGRect] {
            blockers.flatMap { other -> [CGRect] in
                switch axis {
                case .horizontal:
                    return [frame.offsetBy(dx: other.minX - gap - frame.maxX, dy: 0),
                            frame.offsetBy(dx: other.maxX + gap - frame.minX, dy: 0)]
                case .vertical:
                    return [frame.offsetBy(dx: 0, dy: other.minY - gap - frame.maxY),
                            frame.offsetBy(dx: 0, dy: other.maxY + gap - frame.minY)]
                }
            }
        }
        func distance(_ rect: CGRect) -> CGFloat { hypot(rect.minX - frame.minX, rect.minY - frame.minY) }
        let across: Axis = axis == .horizontal ? .vertical : .horizontal
        for pass in [axis, across] {
            let open = candidates(pass).filter { room.contains($0) && !collides($0) }
            if let nearest = open.min(by: { distance($0) < distance($1) }) { return nearest }
        }
        // **Then a step along both at once** — beside one obstacle and under another. One axis at a
        // time missed it: in a narrow column with the save pill up, the capsule at Top Left found no
        // place right of the palette (still under the pill) or under the pill (on the palette), and
        // was drawn over the pill while (58, 52) was free.
        let xs = [frame.minX] + blockers.flatMap { [$0.minX - gap - frame.width, $0.maxX + gap] }
        let ys = [frame.minY] + blockers.flatMap { [$0.minY - gap - frame.height, $0.maxY + gap] }
        let both = xs.flatMap { x in ys.map { y in CGRect(x: x, y: y, width: frame.width, height: frame.height) } }
        if let nearest = both.filter({ room.contains($0) && !collides($0) }).min(by: { distance($0) < distance($1) }) {
            return nearest
        }
        // **Where the canvas has no clear place at all, the piece stays docked and overlaps** —
        // too short for the pieces it holds: the narrowest column on a short window, a form's
        // palette at a side, the find card and the pill all up. Rare enough to leave as it is
        // (his call, 2026-10-19), rather than fold the palette or hide a piece.
        return frame
    }

    /// **The bands the pages keep clear**: ``topBand`` above the first page, and the capsule's own
    /// band on the edge it is docked to — its depth, the inset and a gap — so the end of the last
    /// page can scroll fully clear of it. A corner is on the top or bottom edge. Nothing for the
    /// find card, Fill & Sign's palette or its save pill: opening them must not move the page.
    ///
    /// **The band is the capsule's docked one, even when it has stepped aside** for the palette or
    /// the pill — so while it is aside it can cover a strip of the first or last page. A band that
    /// followed it would move the page whenever Fill & Sign opened; the page stays still (his call,
    /// 2026-10-19).
    static func canvasInsets(place: EditorPDFCapsulePlace, capsule: CGSize) -> NSEdgeInsets {
        var insets = NSEdgeInsets(top: topBand, left: 0, bottom: 0, right: 0)
        guard capsule.width > 0, capsule.height > 0 else { return insets }
        func band(_ depth: CGFloat) -> CGFloat { inset + depth + gap }
        switch place {
        case .topLeading, .top, .topTrailing: insets.top = max(topBand, band(capsule.height))
        case .bottomLeading, .bottom, .bottomTrailing: insets.bottom = band(capsule.height)
        case .leading: insets.left = band(capsule.width)
        case .trailing: insets.right = band(capsule.width)
        }
        return insets
    }
}

/// **What a floating piece stands on**: at Solid a solid shape with a hairline and a soft shadow,
/// as an opaque window draws a panel; in Frosted the app's chrome glass, one capsule round all its
/// buttons (`chromeGlassGroup`); in Clear, Frosted's (``EditorPDFFloating/clearDrawsFrosted``). In
/// dark mode the glass stands on a dark veil (``EditorPDFFloating/veil(material:colorScheme:)``).
struct EditorPDFFloatingGround: ViewModifier {
    let shape: HoverAffordanceShape
    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let floating = EditorPDFFloating.appearance(appearance)
        let veil = EditorPDFFloating.veil(
            material: ChromeGlass.material(appearance: floating, reduceTransparency: reduceTransparency),
            colorScheme: colorScheme)
        content
            .background {
                ChromeGlassTodayGround {
                    shape.outline
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(shape.outline.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                }
            }
            .chromeGlassGroup(shape)
            // After the group, so the veil is behind its glass.
            .background {
                if veil > 0 {
                    shape.outline
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(veil))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .environment(\.selectionLensAppearance, floating)
    }
}

/// **The reader's canvas**: the pages, with the find's matches drawn over them, and the pieces that
/// float over the pages — the page and zoom capsule and the find card (Phase 6a), and while Fill &
/// Sign is on its palette and its save pill (6b). Mounted OVER the page view rather than inside the
/// `PDFView`, so the floating pieces are SwiftUI like the rest of the chrome and PDFKit's own views
/// never cover them.
///
/// **The capsule's and the palette's places are the view state's**; this view only works out where
/// each place is at the canvas's size, keeps the pieces clear of each other, follows a drag, and
/// snaps the drop to the nearest place.
///
/// **Who gives way to whom** (``EditorPDFFloating/clear(_:of:sliding:within:)``): the find card
/// stays in its corner; the save pill slides along the top to clear it; the palette clears both;
/// the capsule clears all three. The capsule is the piece that is always there, so it is the one
/// that moves when another opens where it sits (mockup, "Overlap").
struct EditorPDFReader: View {
    let document: PDFDocument?
    @ObservedObject var state: EditorPDFViewState
    @ObservedObject var find: EditorPDFFind
    /// Not observed: the overlay, the palette and the save pill watch it themselves, so a drag
    /// redraws the overlay and nothing else.
    var fill: EditorPDFFillSign?
    /// What Save Filled Copy runs through — the save pill greys Save while a tool runs.
    var tools: EditorPDFTools?
    var pageCount: Int = 0
    var accent: Color = .accentColor
    /// Fill & Sign's lit tool and Save Filled Copy — see ``EditorWorkspaceView/accentFill``.
    var accentFill: Color = AccentFill.deepened(.accentColor)
    var onAccent: Color = .white

    @State private var canvas: CGSize = .zero
    /// The capsule as it is drawn now, and its last-measured size in each form — the drop measures
    /// every place with the form it would take there.
    @State private var capsule = EditorPDFMeasure()
    @State private var palette = EditorPDFMeasure()
    @State private var findCard: CGSize = .zero
    /// The save pill and the note card under it, as drawn — `.zero` while neither is up.
    @State private var saveStack: CGSize = .zero
    /// The piece the grip is dragging, and how far, while it is held.
    @State private var dragging: EditorPDFMovable?
    @State private var drag: CGSize = .zero

    var body: some View {
        let frames = layout
        ZStack {
            EditorPDFPageView(document: document, state: state, highlights: find.highlights, fill: fill,
                              onEscape: { [find] in
                                  guard find.isShown else { return false }
                                  find.hide()
                                  return true
                              },
                              canvasInsets: EditorPDFFloating.canvasInsets(place: state.capsulePlace, capsule: capsule.now),
                              coveredRects: frames.covered, accent: accent)
            if let dragging {
                let measured = dragging == .capsule ? capsule : palette
                EditorPDFSnapTargets(row: measured.row, upright: measured.upright, canvas: canvas,
                                     hot: dropPlace(for: dragging, moved: drag, frames: frames), accent: accent,
                                     radius: dragging == .palette ? Radius.card : nil)
            }
            if let fill {
                EditorPDFFillPalette(fill: fill, state: state, place: state.palettePlace, accent: accent,
                                     accentFill: accentFill, onAccent: onAccent,
                                     onDrag: { moved in
                                         dragging = .palette
                                         drag = moved
                                     },
                                     onDrop: { moved in drop(.palette, moved: moved, frames: frames) },
                                     onSize: { size in
                                         palette.measured(size, upright: state.palettePlace.isVertical)
                                         // **The palette went while its grip was held** — a save
                                         // landed mid-drag. The drag goes with it: left set, the
                                         // snap targets stayed drawn, and a late drop stored the
                                         // place nearest the corner of an empty frame.
                                         if size == .zero, dragging == .palette { dragging = nil; drag = .zero }
                                     })
                    .offset(offset(of: .palette, frames: frames))
                    .designAnimation(.easeOut(duration: 0.2), value: state.palettePlace)
                    .designAnimation(.easeOut(duration: 0.2), value: find.isShown)
                    .designAnimation(.easeOut(duration: 0.2), value: frames.saveStack)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.palettePlace.alignment)
                    .padding(EditorPDFFloating.inset)
                if let tools {
                    EditorPDFFillSaveStack(fill: fill, tools: tools, accentFill: accentFill, onSize: { saveStack = $0 })
                        .offset(x: frames.saveStack.minX - frames.saveStackDocked.minX,
                                y: frames.saveStack.minY - frames.saveStackDocked.minY)
                        .designAnimation(.easeOut(duration: 0.2), value: find.isShown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(EditorPDFFloating.inset)
                }
            }
            if pageCount > 0 {
                EditorPDFCapsule(state: state, pageCount: pageCount, accent: accent,
                                 onDrag: { moved in
                                     dragging = .capsule
                                     drag = moved
                                 },
                                 onDrop: { moved in drop(.capsule, moved: moved, frames: frames) })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        capsule.measured(size, upright: state.capsulePlace.isVertical)
                    }
                    .offset(offset(of: .capsule, frames: frames))
                    .designAnimation(.easeOut(duration: 0.2), value: state.capsulePlace)
                    .designAnimation(.easeOut(duration: 0.2), value: find.isShown)
                    .designAnimation(.easeOut(duration: 0.2), value: frames.palette)
                    .designAnimation(.easeOut(duration: 0.2), value: frames.saveStack)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.capsulePlace.alignment)
                    .padding(EditorPDFFloating.inset)
            }
            EditorPDFFindBar(find: find, accent: accent)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { findCard = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(EditorPDFFloating.inset)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvas = $0 }
    }

    /// Where each floating piece sits at its place, and where it is shown once clear of the others.
    struct Frames {
        var findCard = CGRect.zero
        var saveStackDocked = CGRect.zero
        var saveStack = CGRect.zero
        var paletteDocked = CGRect.zero
        var palette = CGRect.zero
        var capsuleDocked = CGRect.zero
        var capsule = CGRect.zero

        /// **What covers the pages outside their bands** — the find card, the save pill, the
        /// palette, and the capsule once it has slid off its own band — for "is a match in sight"
        /// (``ReaderPDFView/coveredRects``). The pages keep no band for these: opening one must not
        /// move them.
        var covered: [CGRect] {
            [findCard, saveStack, palette].filter { !$0.isEmpty } + (capsule == capsuleDocked ? [] : [capsule])
        }
    }

    /// **The pieces in the order they give way** — each slid along its own edge clear of the ones
    /// before it. A piece not drawn is `.zero`, which the rule ignores.
    private var layout: Frames {
        Self.layout(canvas: canvas, findCard: find.isShown ? findCard : .zero, saveStack: saveStack,
                    palette: palette.now, palettePlace: state.palettePlace,
                    capsule: capsule.now, capsulePlace: state.capsulePlace)
    }

    static func layout(canvas: CGSize, findCard: CGSize, saveStack: CGSize,
                       palette: CGSize, palettePlace: EditorPDFCapsulePlace,
                       capsule: CGSize, capsulePlace: EditorPDFCapsulePlace) -> Frames {
        func drawn(_ size: CGSize) -> Bool { size.width > 0 && size.height > 0 }
        var frames = Frames()
        if drawn(findCard) { frames.findCard = EditorPDFCapsulePlace.topTrailing.frame(size: findCard, in: canvas) }
        if drawn(saveStack) {
            frames.saveStackDocked = EditorPDFCapsulePlace.top.frame(size: saveStack, in: canvas)
            frames.saveStack = EditorPDFFloating.clear(frames.saveStackDocked, of: [frames.findCard],
                                                       sliding: .horizontal, within: canvas)
        }
        if drawn(palette) {
            frames.paletteDocked = palettePlace.frame(size: palette, in: canvas)
            frames.palette = EditorPDFFloating.clear(frames.paletteDocked, of: [frames.findCard, frames.saveStack],
                                                     sliding: palettePlace.slideAxis, within: canvas)
        }
        frames.capsuleDocked = capsulePlace.frame(size: capsule, in: canvas)
        frames.capsule = EditorPDFFloating.clear(frames.capsuleDocked,
                                                 of: [frames.findCard, frames.saveStack, frames.palette],
                                                 sliding: capsulePlace.slideAxis, within: canvas)
        return frames
    }

    /// How far a piece is drawn from its place: slid clear of the others, plus the drag while held.
    private func offset(of piece: EditorPDFMovable, frames: Frames) -> CGSize {
        let (shown, docked) = piece == .capsule ? (frames.capsule, frames.capsuleDocked)
                                                : (frames.palette, frames.paletteDocked)
        let held = dragging == piece ? drag : .zero
        return CGSize(width: shown.minX - docked.minX + held.width, height: shown.minY - docked.minY + held.height)
    }

    private func drop(_ piece: EditorPDFMovable, moved: CGSize, frames: Frames) {
        // Only the drag that is still held: one let go of when its piece went is no drop.
        guard dragging == piece else { return }
        let landed = dropPlace(for: piece, moved: moved, frames: frames)
        dragging = nil
        drag = .zero
        state[keyPath: piece.place] = landed
    }

    /// The place a piece lands in if let go `moved` from where it is shown: the nearest to its
    /// centre there, each place measured with the form the piece takes at it.
    private func dropPlace(for piece: EditorPDFMovable, moved: CGSize, frames: Frames) -> EditorPDFCapsulePlace {
        let (shown, measured) = piece == .capsule ? (frames.capsule, capsule) : (frames.palette, palette)
        return EditorPDFCapsulePlace.nearest(to: CGPoint(x: shown.midX + moved.width, y: shown.midY + moved.height),
                                             horizontal: measured.row, vertical: measured.upright, in: canvas)
    }
}

/// **A movable piece's sizes**: as drawn now, and last measured in each form — a row and a column —
/// so a drop can measure every place with the form the piece would take there.
struct EditorPDFMeasure: Equatable {
    var now: CGSize = .zero
    var row: CGSize = .zero
    var upright: CGSize = .zero

    mutating func measured(_ size: CGSize, upright isUpright: Bool) {
        now = size
        guard size != .zero else { return }
        if isUpright { upright = size } else { row = size }
    }
}

/// **The eight places, drawn while the capsule or the palette is dragged** (mockup H) — the one
/// it would land in lit. Drawn only, never hit: the drag is the grip's.
struct EditorPDFSnapTargets: View {
    let row: CGSize
    let upright: CGSize
    let canvas: CGSize
    let hot: EditorPDFCapsulePlace
    let accent: Color
    /// The piece's corner radius — `nil` for the capsule's own round ends.
    var radius: CGFloat?

    var body: some View {
        let standing = upright == .zero ? CGSize(width: row.height, height: row.width) : upright
        let lying = row == .zero ? CGSize(width: standing.height, height: standing.width) : row
        ZStack(alignment: .topLeading) {
            ForEach(EditorPDFCapsulePlace.allCases, id: \.self) { place in
                let frame = place.frame(size: place.isVertical ? standing : lying, in: canvas)
                Group {
                    if let radius {
                        target(RoundedRectangle(cornerRadius: radius), lit: place == hot)
                    } else {
                        target(Capsule(), lit: place == hot)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func target(_ shape: some InsettableShape, lit: Bool) -> some View {
        shape
            .strokeBorder(accent.opacity(lit ? 1 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: lit ? [] : [4, 3]))
            .background(shape.fill(accent.opacity(lit ? 0.14 : 0)))
    }
}
