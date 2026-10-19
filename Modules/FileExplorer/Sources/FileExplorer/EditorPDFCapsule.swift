import AppKit
import SwiftUI
import Design

/// **Where the page and zoom capsule floats** (Phase 6a, mockup H): the four corners, the middle of
/// the top and the bottom, and the middle of each side — each inset ``EditorPDFFloating/inset``
/// from the canvas's edges. Bottom centre until it is moved.
///
/// **A place, never points**, which is what makes it safe to remember: the canvas changes size with
/// the window, the rail and the text size, and "bottom right" is bottom right at every one of them.
/// Stored under ``EditorPDFSettings/capsulePlaceKey`` by its raw value.
public enum EditorPDFCapsulePlace: String, CaseIterable, Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    /// What Move To calls it, and what its accessibility action says after "Move to".
    public var title: String {
        switch self {
        case .topLeading: return "Top Left"
        case .top: return "Top Centre"
        case .topTrailing: return "Top Right"
        case .leading: return "Middle Left"
        case .trailing: return "Middle Right"
        case .bottomLeading: return "Bottom Left"
        case .bottom: return "Bottom Centre"
        case .bottomTrailing: return "Bottom Right"
        }
    }

    /// **Upright only in the middle of a side** — there a row would reach across the page it is
    /// meant to stay out of the way of. In a corner the capsule sits along the top or bottom edge,
    /// so it stays a row.
    public var isVertical: Bool { self == .leading || self == .trailing }

    /// Which way the capsule slides to keep clear of another floating piece: along the edge it is
    /// docked to (``EditorPDFFloating/clear(_:of:sliding:within:)``).
    var slideAxis: Axis { isVertical ? .vertical : .horizontal }

    /// Whether it sits along the bottom edge — where its menu opens upwards.
    var isAtBottom: Bool { self == .bottomLeading || self == .bottom || self == .bottomTrailing }

    var isAtTop: Bool { self == .topLeading || self == .top || self == .topTrailing }

    /// The canvas alignment that puts a view of any size at this place, inside the inset.
    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .top: return .top
        case .topTrailing: return .topTrailing
        case .leading: return .leading
        case .trailing: return .trailing
        case .bottomLeading: return .bottomLeading
        case .bottom: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// **Where a capsule of `size` sits at this place on a `canvas`**, in the canvas's own
    /// top-left-origin space — the frame ``alignment`` gives it inside the inset, worked out rather
    /// than read back, so the overlap rule and the drop can use it without a measurement.
    func frame(size: CGSize, in canvas: CGSize, inset: CGFloat = EditorPDFFloating.inset) -> CGRect {
        let left = inset, centreX = (canvas.width - size.width) / 2, right = canvas.width - inset - size.width
        let top = inset, centreY = (canvas.height - size.height) / 2, bottom = canvas.height - inset - size.height
        let origin: CGPoint
        switch self {
        case .topLeading: origin = CGPoint(x: left, y: top)
        case .top: origin = CGPoint(x: centreX, y: top)
        case .topTrailing: origin = CGPoint(x: right, y: top)
        case .leading: origin = CGPoint(x: left, y: centreY)
        case .trailing: origin = CGPoint(x: right, y: centreY)
        case .bottomLeading: origin = CGPoint(x: left, y: bottom)
        case .bottom: origin = CGPoint(x: centreX, y: bottom)
        case .bottomTrailing: origin = CGPoint(x: right, y: bottom)
        }
        return CGRect(origin: origin, size: size)
    }

    /// **The place a capsule dropped with its centre at `point` snaps to**: the one whose own centre
    /// is nearest — measured on the capsule as it would sit there, upright at the sides, so on a
    /// narrow canvas, where a corner and the middle of its edge nearly coincide, a drop does not
    /// wander from one to the other.
    ///
    /// `vertical` is the upright capsule's size, or `.zero` when it has not been drawn yet — then
    /// the row's size turned on its side stands in.
    static func nearest(to point: CGPoint, horizontal: CGSize, vertical: CGSize,
                        in canvas: CGSize) -> EditorPDFCapsulePlace {
        let upright = vertical == .zero ? CGSize(width: horizontal.height, height: horizontal.width) : vertical
        let row = horizontal == .zero ? CGSize(width: upright.height, height: upright.width) : horizontal
        func distance(_ place: EditorPDFCapsulePlace) -> CGFloat {
            let frame = place.frame(size: place.isVertical ? upright : row, in: canvas)
            return hypot(frame.midX - point.x, frame.midY - point.y)
        }
        return allCases.min { distance($0) < distance($1) } ?? EditorPDFSettings.capsulePlaceDefault
    }
}

/// **The two pieces a reader can move over the canvas** — the page and zoom capsule (6a) and Fill
/// & Sign's palette (6b). Each has its own place in the view state, its own place to go back to,
/// and its own words on the grip; the grip, its menu and its accessibility actions are one for both.
enum EditorPDFMovable: CaseIterable, Sendable {
    case capsule
    case palette

    /// Where the view state keeps this piece's place.
    @MainActor var place: ReferenceWritableKeyPath<EditorPDFViewState, EditorPDFCapsulePlace> {
        switch self {
        case .capsule: return \.capsulePlace
        case .palette: return \.palettePlace
        }
    }

    /// Where a double-click and Reset Position put it back.
    var home: EditorPDFCapsulePlace {
        switch self {
        case .capsule: return EditorPDFSettings.capsulePlaceDefault
        case .palette: return EditorPDFSettings.palettePlaceDefault
        }
    }

    var tooltip: String {
        switch self {
        case .capsule: return "Drag to move the page controls — double-click to put them back at the bottom"
        case .palette: return "Drag to move the Fill & Sign tools — double-click to put them back at the left"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .capsule: return "Move the page controls"
        case .palette: return "Move the Fill & Sign tools"
        }
    }
}

/// **The page and zoom capsule** (Phase 6a, mockups C, D, E and H) — the reader's page, zoom and
/// view menu, floating in glass over the canvas instead of sharing the header with the file's own
/// actions: a grip, ‹, the page field ("N of M", "6–7 of 64" for a spread), ›, a divider, −, the
/// zoom label ▾ and +. Always fully visible — no fading.
///
/// **Its own view, observing the view state alone**, as the header controls it replaced were: a
/// page turn re-renders this and row 2's paper, and nothing else above the pages.
///
/// **Upright in the middle of a side** (``EditorPDFCapsulePlace/isVertical``): ‹ › become ˄ ˅, "N"
/// sits over "of M", + is on top, and the label says the percentage — "86%" — so the capsule stays
/// narrow. Its menu still ticks the fit.
///
/// **What a narrow canvas takes, in order** (decided 2026-10-19): − and + first — Zoom In and Zoom
/// Out are in the menu and on ⌘+ and ⌘− — then ‹ and ›, which ⌥← and ⌥→ and the field stand in
/// for. "N of M" and the zoom label always stay, and "Fit Page" is never cut to "Fit".
struct EditorPDFCapsule: View {
    @ObservedObject var state: EditorPDFViewState
    let pageCount: Int
    let accent: Color
    /// The grip's drag as it goes, and where it was let go — the canvas moves and snaps it.
    var onDrag: (CGSize) -> Void = { _ in }
    var onDrop: (CGSize) -> Void = { _ in }
    /// Forces a rung — for the tests that measure each one. `nil` picks by the room there is.
    var forcedRung: Rung?
    @State private var typedPage = ""
    @FocusState private var pageFieldFocused: Bool
    /// Where the view menu opens from.
    private let zoomAnchor = EditorHeadingMenuAnchor()

    /// The capsule's readings, widest first — what a narrow canvas drops, in the order it goes.
    enum Rung: CaseIterable {
        case full
        case noZoomSteps
        case pageAndZoomOnly

        var showsZoomSteps: Bool { self == .full }
        var showsPageSteps: Bool { self != .pageAndZoomOnly }
    }

    private var isVertical: Bool { state.capsulePlace.isVertical }

    var body: some View {
        rungs
            .modifier(EditorPDFFloatingGround(shape: .capsule))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Page and zoom")
            .onAppear { typedPage = Self.pageText(state.visiblePages) }
            .onChange(of: state.visiblePages) { _, pages in
                if !pageFieldFocused { typedPage = Self.pageText(pages) }
            }
            .onChange(of: pageFieldFocused) { _, focused in
                if !focused { typedPage = Self.pageText(state.visiblePages) }
            }
            // Text ▸ Go to Page… ⌃⌘L puts the caret in this field.
            .onChange(of: state.pageFieldRequest) { _, _ in pageFieldFocused = true }
    }

    /// The rung the room allows — measured along the capsule's own length, which is its height
    /// when it stands upright.
    @ViewBuilder
    private var rungs: some View {
        if let forcedRung {
            content(forcedRung)
        } else if isVertical {
            ViewThatFits(in: .vertical) {
                ForEach(Rung.allCases, id: \.self) { content($0) }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(Rung.allCases, id: \.self) { content($0) }
            }
        }
    }

    @ViewBuilder
    func content(_ rung: Rung) -> some View {
        if isVertical {
            VStack(spacing: 2) {
                grip
                if rung.showsPageSteps { pageStep(forward: false) }
                pageField
                if rung.showsPageSteps { pageStep(forward: true) }
                divider
                // Bigger on top, as a stack of sizes reads.
                if rung.showsZoomSteps { zoomStep(in: true) }
                zoomLabel
                if rung.showsZoomSteps { zoomStep(in: false) }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        } else {
            HStack(spacing: 2) {
                grip
                if rung.showsPageSteps { pageStep(forward: false) }
                pageField
                if rung.showsPageSteps { pageStep(forward: true) }
                divider
                if rung.showsZoomSteps { zoomStep(in: false) }
                zoomLabel
                if rung.showsZoomSteps { zoomStep(in: true) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    // MARK: The grip

    private var grip: some View {
        EditorPDFGripHandle(state: state, piece: .capsule, upright: isVertical, onDrag: onDrag, onDrop: onDrop)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: isVertical ? 16 : 1, height: isVertical ? 1 : 16)
            .padding(isVertical ? .vertical : .horizontal, 3)
            .accessibilityHidden(true)
    }

    // MARK: The page

    /// ‹ and › — ˄ and ˅ upright: the spread before or after the one on screen.
    private func pageStep(forward: Bool) -> some View {
        let label = forward ? "Next page" : "Previous page"
        let symbol = isVertical ? (forward ? "chevron.down" : "chevron.up")
                                : (forward ? "chevron.right" : "chevron.left")
        return Button { state.turnPage(forward: forward) } label: {
            Image(systemName: symbol)
                .scaledFont(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(!state.canTurnPage(forward: forward))
        .accessibilityLabel(label)
        .help(label)
    }

    /// "2 of 3", the number a field: type a page and Return. In a two-page layout it shows the
    /// spread, "6–7 of 64", and a page typed there goes to the spread that holds it. Upright, "of 3"
    /// goes under the number.
    @ViewBuilder
    private var pageField: some View {
        let field = TextField("", text: $typedPage)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: Self.fieldWidth(pageCount: pageCount, twoUp: state.layout.isTwoUp))
            .focused($pageFieldFocused)
            .onSubmit { go() }
            .accessibilityLabel(state.layout.isTwoUp ? "Pages" : "Page")
            .accessibilityValue("\(typedPage) of \(pageCount)")
        let count = Text("of \(pageCount)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
        Group {
            if isVertical {
                VStack(spacing: 2) {
                    field
                    count
                }
            } else {
                HStack(spacing: 4) {
                    field
                    count
                }
            }
        }
        .scaledFont(.system(size: 10))
        .padding(.horizontal, isVertical ? 0 : 2)
    }

    /// What the field says: "7", or "6–7" for a spread — one-based, as the reader counts.
    static func pageText(_ pages: ClosedRange<Int>) -> String {
        pages.count == 1 ? String(pages.lowerBound + 1) : "\(pages.lowerBound + 1)–\(pages.upperBound + 1)"
    }

    /// Wide enough for the longest number this document has — or two of them and a dash, in a
    /// two-page layout — and no wider.
    static func fieldWidth(pageCount: Int, twoUp: Bool = false) -> CGFloat {
        let digits = max(String(pageCount).count, 2)
        return CGFloat(twoUp ? 2 * digits + 1 : digits) * 8 + 14
    }

    private func go() {
        guard let page = Self.page(typed: typedPage, pageCount: pageCount) else {
            typedPage = Self.pageText(state.visiblePages)
            return
        }
        state.requestPage(page)
        pageFieldFocused = false
    }

    /// The zero-based page a typed number names, clamped into the document; `nil` for no number.
    /// The FIRST number counts, so a spread's own "6–7" sent back unchanged goes to 6 — the spread
    /// it already is.
    static func page(typed: String, pageCount: Int) -> Int? {
        let digits = typed.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard pageCount > 0, let number = Int(digits) else { return nil }
        return min(max(number, 1), pageCount) - 1
    }

    // MARK: The zoom

    private func zoomStep(in zoomingIn: Bool) -> some View {
        let label = zoomingIn ? "Zoom in" : "Zoom out"
        return Button { state.zoom(in: zoomingIn) } label: {
            Image(systemName: zoomingIn ? "plus" : "minus")
                .scaledFont(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(!state.canZoom(in: zoomingIn))
        .accessibilityLabel(label)
        .help(label)
    }

    /// The label that opens the view menu (mockup E): the fit, or the percentage — always the
    /// percentage upright, where "Fit Width" would widen the whole capsule.
    private var zoomLabel: some View {
        let said = EditorPDFZoom.label(fit: state.fit, scale: state.scale)
        return Button {
            Self.present(EditorPDFViewMenu.menu(for: state), from: zoomAnchor.view, place: state.capsulePlace)
        } label: {
            HStack(spacing: 3) {
                Text(isVertical ? EditorPDFZoom.percent(state.scale) : said)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                if !isVertical {
                    Image(systemName: "chevron.down")
                        .scaledFont(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .scaledFont(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent))
        .background(EditorHeadingMenuAnchor.Probe(anchor: zoomAnchor))
        .accessibilityLabel("Zoom and page layout")
        .accessibilityValue(said)
        .help("\(said) — zoom, the fits and Page Layout")
    }

    /// **Opens `menu` on the side of the label away from the edge the capsule is docked to** —
    /// above it at the bottom, so Page Layout, the menu's last row, is the one nearest the capsule
    /// (mockup E); below it at the top; beside it at the sides.
    static func present(_ menu: NSMenu, from view: NSView?, place: EditorPDFCapsulePlace) {
        guard let view else { return }
        let size = menu.size
        let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY
        let bottom = view.isFlipped ? view.bounds.maxY : view.bounds.minY
        let up: CGFloat = view.isFlipped ? -1 : 1
        let point: NSPoint
        switch place {
        case .leading:
            point = NSPoint(x: view.bounds.maxX + 4, y: top)
        case .trailing:
            point = NSPoint(x: view.bounds.minX - size.width - 4, y: top)
        case .bottomLeading, .bottom, .bottomTrailing:
            point = NSPoint(x: 0, y: top + up * (size.height + 2))
        case .topLeading, .top, .topTrailing:
            point = NSPoint(x: 0, y: bottom - up * 2)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

// MARK: - The grip

/// **The one part of a movable piece that drags** — the buttons never do. Its dots are drawn here;
/// the handling is ``EditorPDFGripView``'s, laid over them: the drag, the double-click that resets,
/// the right-click Move To menu and the same items as accessibility actions. `upright` is the
/// piece's own form: a column's grip is a short row of dots across its top, a row's a short column
/// at its start.
struct EditorPDFGripHandle: View {
    let state: EditorPDFViewState
    let piece: EditorPDFMovable
    let upright: Bool
    var onDrag: (CGSize) -> Void
    var onDrop: (CGSize) -> Void

    var body: some View {
        let width: CGFloat = upright ? 22 : 12
        let height: CGFloat = upright ? 12 : 22
        let columns = upright ? 3 : 2, rows = upright ? 2 : 3
        Canvas { context, size in
            let pitch: CGFloat = 4
            let origin = CGPoint(x: (size.width - CGFloat(columns - 1) * pitch) / 2,
                                 y: (size.height - CGFloat(rows - 1) * pitch) / 2)
            for row in 0..<rows {
                for column in 0..<columns {
                    let centre = CGPoint(x: origin.x + CGFloat(column) * pitch, y: origin.y + CGFloat(row) * pitch)
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 1, y: centre.y - 1, width: 2, height: 2)),
                                 with: .color(.secondary))
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
        .overlay(EditorPDFGrip(state: state, piece: piece, onDrag: onDrag, onDrop: onDrop))
    }
}

/// The grip's handling, as an AppKit view laid over its dots — see ``EditorPDFGripView``.
struct EditorPDFGrip: NSViewRepresentable {
    let state: EditorPDFViewState
    var piece: EditorPDFMovable = .capsule
    var onDrag: (CGSize) -> Void
    var onDrop: (CGSize) -> Void

    func makeNSView(context: Context) -> EditorPDFGripView {
        let view = EditorPDFGripView()
        update(view)
        return view
    }

    func updateNSView(_ view: EditorPDFGripView, context: Context) { update(view) }

    private func update(_ view: EditorPDFGripView) {
        view.state = state
        view.piece = piece
        // On the view itself: it lies over the dots, so a SwiftUI `.help` under it would never show.
        view.toolTip = piece.tooltip
        view.onDrag = onDrag
        view.onDrop = onDrop
    }
}

/// **A movable piece's grip: the drag, the double-click, Move To, and their accessibility actions**
/// — the capsule's, and Fill & Sign's palette's (``piece``).
///
/// **AppKit rather than a SwiftUI gesture**, for three reasons that are each a test: a drag that
/// starts on the grip and never on a button is the view's own mouse handling, not a gesture racing
/// the buttons beside it; a double-click is `clickCount`, which a test can send; and the right-click
/// menu and the accessibility actions are ordinary `NSMenu` items and `NSAccessibilityCustomAction`s,
/// which a test can read and fire — a hosted SwiftUI `Menu`'s body never runs offscreen.
final class EditorPDFGripView: NSView {
    weak var state: EditorPDFViewState?
    /// Which piece this grip moves — whose place it sets and where it goes back to.
    var piece = EditorPDFMovable.capsule
    var onDrag: (CGSize) -> Void = { _ in }
    var onDrop: (CGSize) -> Void = { _ in }
    private var start: NSPoint?
    private var isDragging = false

    /// How far the pointer moves before a press is a drag — under it, a click is only a click, and
    /// the first half of a double-click moves nothing.
    static let dragThreshold: CGFloat = 3

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            start = nil
            isDragging = false
            resetPosition()
            return
        }
        start = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let moved = Self.translation(from: start, to: event.locationInWindow)
        if !isDragging, hypot(moved.width, moved.height) < Self.dragThreshold { return }
        isDragging = true
        NSCursor.closedHand.set()
        onDrag(moved)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            isDragging = false
        }
        guard let start, isDragging else { return }
        onDrop(Self.translation(from: start, to: event.locationInWindow))
    }

    /// A window's y runs up and SwiftUI's runs down, so the drag is turned over on the way out.
    static func translation(from start: NSPoint, to end: NSPoint) -> CGSize {
        CGSize(width: end.x - start.x, height: start.y - end.y)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        state.map { EditorPDFCapsuleMenu.menu(for: $0, piece: piece) }
    }

    /// Double-click and Reset Position: the piece's own place again — bottom centre for the
    /// capsule, the middle of the left side for the palette.
    func resetPosition() {
        state?[keyPath: piece.place] = piece.home
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .handle }
    override func accessibilityLabel() -> String? { piece.accessibilityLabel }
    override func accessibilityValue() -> Any? { state?[keyPath: piece.place].title }

    /// **Move To's places and Reset Position, as actions** — so moving the capsule never needs a
    /// drag, with VoiceOver or anything else.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let state else { return nil }
        return EditorPDFCapsuleMenu.actions(for: state, piece: piece).map { action in
            NSAccessibilityCustomAction(name: action.title) {
                action.perform()
                return true
            }
        }
    }
}

/// **The grip's right-click menu** (mockup H): Move To ▸ the eight places, the current one ticked,
/// and Reset Position — and the same items as the grip's accessibility actions. The capsule's and
/// the palette's, each moving its own piece.
@MainActor
enum EditorPDFCapsuleMenu {
    static let moveToTitle = "Move To"
    static let resetTitle = "Reset Position"

    /// One thing the grip can be asked to do.
    struct Action {
        let title: String
        let perform: () -> Void
    }

    /// The accessibility actions: "Move to Top Left" … "Move to Bottom Right", then Reset Position.
    static func actions(for state: EditorPDFViewState, piece: EditorPDFMovable = .capsule) -> [Action] {
        EditorPDFCapsulePlace.allCases.map { place in
            Action(title: "Move to \(place.title)") { state[keyPath: piece.place] = place }
        } + [Action(title: resetTitle) { state[keyPath: piece.place] = piece.home }]
    }

    static func menu(for state: EditorPDFViewState, piece: EditorPDFMovable = .capsule) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let places = NSMenu(title: moveToTitle)
        places.autoenablesItems = false
        for place in EditorPDFCapsulePlace.allCases {
            // The rows of the canvas, top to bottom, a separator between each.
            if place == .leading || place == .bottomLeading { places.addItem(.separator()) }
            let item = EditorClosureMenuItem(title: place.title) { state[keyPath: piece.place] = place }
            item.state = state[keyPath: piece.place] == place ? .on : .off
            places.addItem(item)
        }
        let moveTo = NSMenuItem(title: moveToTitle, action: nil, keyEquivalent: "")
        moveTo.submenu = places
        menu.addItem(moveTo)
        let reset = EditorClosureMenuItem(title: resetTitle) { state[keyPath: piece.place] = piece.home }
        reset.isEnabled = state[keyPath: piece.place] != piece.home
        menu.addItem(reset)
        return menu
    }
}
