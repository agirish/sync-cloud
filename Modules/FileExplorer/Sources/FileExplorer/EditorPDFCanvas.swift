import AppKit
import PDFKit
import SwiftUI
import Design

/// **The rules every piece floating over the PDF canvas keeps** (Phase 6a) — the page and zoom
/// capsule and the find card now, Fill & Sign's palette and save pill in 6b. Written once, here, so
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

    /// **Floating pieces never overlap.** `frame` slid along `axis` — the edge it is docked to —
    /// until it clears every one of `obstacles` by ``gap``, staying inside the canvas's inset; the
    /// nearer way wins. Only where no place along that edge is clear does it step across the edge
    /// instead, below or beside the obstacle. `frame` itself when nothing is in the way, so the
    /// piece goes back the moment the other one closes.
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
        return frame
    }

    /// **The bands the pages keep clear**: ``topBand`` above the first page, and the capsule's own
    /// band on the edge it is docked to — its depth, the inset and a gap — so the end of the last
    /// page can scroll fully clear of it. A corner is on the top or bottom edge. Nothing for the
    /// find card: opening it must not move the page.
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
/// buttons (`chromeGlassGroup`); in Clear, Frosted's (``EditorPDFFloating/clearDrawsFrosted``).
struct EditorPDFFloatingGround: ViewModifier {
    let shape: HoverAffordanceShape
    @Environment(\.selectionLensAppearance) private var appearance

    func body(content: Content) -> some View {
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
            .environment(\.selectionLensAppearance, EditorPDFFloating.appearance(appearance))
    }
}

/// **The reader's canvas**: the pages, with the find's matches drawn over them, and the pieces that
/// float over the pages — the page and zoom capsule and the find card (Phase 6a). Mounted OVER the
/// page view rather than inside the `PDFView`, so the floating pieces are SwiftUI like the rest of
/// the chrome and PDFKit's own views never cover them.
///
/// **The capsule's place is the view state's**; this view only works out where that place is at
/// the canvas's size, keeps it clear of the find card, follows a drag, and snaps the drop to the
/// nearest place.
struct EditorPDFReader: View {
    let document: PDFDocument?
    @ObservedObject var state: EditorPDFViewState
    @ObservedObject var find: EditorPDFFind
    /// Not observed: the overlay watches it itself, so a drag redraws the overlay and nothing else.
    var fill: EditorPDFFillSign?
    var pageCount: Int = 0
    var accent: Color = .accentColor

    @State private var canvas: CGSize = .zero
    /// The capsule as it is drawn now, and its last-measured size in each form — the drop measures
    /// every place with the form it would take there.
    @State private var capsule: CGSize = .zero
    @State private var rowSize: CGSize = .zero
    @State private var uprightSize: CGSize = .zero
    @State private var findCard: CGSize = .zero
    /// How far the grip has dragged the capsule, while it is held.
    @State private var drag: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        let place = state.capsulePlace
        let docked = place.frame(size: capsule, in: canvas)
        let shown = EditorPDFFloating.clear(docked, of: obstacles, sliding: place.slideAxis, within: canvas)
        ZStack {
            EditorPDFPageView(document: document, state: state, highlights: find.highlights, fill: fill,
                              onEscape: { [find] in
                                  guard find.isShown else { return false }
                                  find.hide()
                                  return true
                              },
                              canvasInsets: EditorPDFFloating.canvasInsets(place: place, capsule: capsule))
            if isDragging {
                EditorPDFSnapTargets(row: rowSize, upright: uprightSize, canvas: canvas,
                                     hot: dropPlace(for: shown, moved: drag), accent: accent)
            }
            if pageCount > 0 {
                EditorPDFCapsule(state: state, pageCount: pageCount, accent: accent,
                                 onDrag: { moved in
                                     isDragging = true
                                     drag = moved
                                 },
                                 onDrop: { moved in
                                     let landed = dropPlace(for: shown, moved: moved)
                                     isDragging = false
                                     drag = .zero
                                     state.capsulePlace = landed
                                 })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        capsule = size
                        if state.capsulePlace.isVertical { uprightSize = size } else { rowSize = size }
                    }
                    .offset(x: shown.minX - docked.minX + drag.width, y: shown.minY - docked.minY + drag.height)
                    .designAnimation(.easeOut(duration: 0.2), value: place)
                    .designAnimation(.easeOut(duration: 0.2), value: find.isShown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: place.alignment)
                    .padding(EditorPDFFloating.inset)
            }
            EditorPDFFindBar(find: find, accent: accent)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { findCard = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(EditorPDFFloating.inset)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvas = $0 }
    }

    /// What the capsule must keep clear of: the find card, while it is up — top right, as
    /// ``EditorPDFFindBar`` is placed.
    private var obstacles: [CGRect] {
        guard find.isShown, findCard.width > 0, findCard.height > 0 else { return [] }
        return [EditorPDFCapsulePlace.topTrailing.frame(size: findCard, in: canvas)]
    }

    /// The place the capsule lands in if let go `moved` from where it is shown: the nearest to its
    /// centre there.
    private func dropPlace(for shown: CGRect, moved: CGSize) -> EditorPDFCapsulePlace {
        EditorPDFCapsulePlace.nearest(to: CGPoint(x: shown.midX + moved.width, y: shown.midY + moved.height),
                                      horizontal: rowSize, vertical: uprightSize, in: canvas)
    }
}

/// **The eight places, drawn while the capsule is dragged** (mockup H) — the one it would land in
/// lit. Drawn only, never hit: the drag is the grip's.
struct EditorPDFSnapTargets: View {
    let row: CGSize
    let upright: CGSize
    let canvas: CGSize
    let hot: EditorPDFCapsulePlace
    let accent: Color

    var body: some View {
        let standing = upright == .zero ? CGSize(width: row.height, height: row.width) : upright
        let lying = row == .zero ? CGSize(width: standing.height, height: standing.width) : row
        ZStack(alignment: .topLeading) {
            ForEach(EditorPDFCapsulePlace.allCases, id: \.self) { place in
                let frame = place.frame(size: place.isVertical ? standing : lying, in: canvas)
                Capsule()
                    .strokeBorder(accent.opacity(place == hot ? 1 : 0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: place == hot ? [] : [4, 3]))
                    .background(Capsule().fill(accent.opacity(place == hot ? 0.14 : 0)))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
