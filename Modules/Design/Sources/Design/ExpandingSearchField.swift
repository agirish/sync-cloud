import SwiftUI

/// The app's one expand-on-demand search: a magnifier that reveals a field, the field itself, and
/// the focus / Escape / clear behaviour between them. Every surface with a token search uses it,
/// so search behaves the same everywhere by construction.
///
/// The toggle and field are separate views on different rows of their host: the toggle ends the
/// controls row, the field appears below it. The host owns their shared `text` and `isExpanded`.
public enum ExpandingSearch {
    /// The reveal/collapse animation. One constant, so the toggle and any host layout that keys
    /// off `isExpanded` (a card growing to fit the field) move as one.
    public static let animation: Animation = .easeOut(duration: 0.15)

    /// Collapses and clears in one animated transaction, as Escape and the toggle's second click
    /// both do. A query left live behind a hidden field would be a filter you can't see or undo.
    ///
    /// `reduceMotion` has no default on purpose: a default lets a caller animate with the setting
    /// on without noticing it had a choice.
    public static func collapse(text: Binding<String>, isExpanded: Binding<Bool>, reduceMotion: Bool) {
        withDesignAnimation(animation, reduceMotion: reduceMotion) {
            text.wrappedValue = ""
            isExpanded.wrappedValue = false
        }
    }

    // MARK: Opening in glass (RD46.10)
    //
    // Solid, Reduce Transparency and Reduce Motion fade the field in on the host's transition. In
    // Frosted and Clear the surface travels out of the magnifier's end like a selection lens: a
    // magnifier-sized pill at the trailing edge springs to full width on the lens's springs, and
    // the query fades in once there is room. Closing fades in every appearance. The surface is the
    // same wash every search field wears; glass changes only how it opens.
    //
    // Only an animated insertion travels (the magnifier and ⌘F make one). A view that comes back
    // with a search already open inserts the field without animation, so it is simply there.
    //
    // The field runs its own frame clock rather than a transition, because nothing a `Transition`'s
    // modifiers write (even a constant environment value) reaches the view inside: a transition can
    // fade the field but not move its surface. The field reads the transaction that inserted it.

    /// Whether the field opens by travelling rather than fading.
    public static func travels(appearance: SelectionLensAppearance, reduceTransparency: Bool,
                               reduceMotion: Bool) -> Bool {
        !reduceMotion
            && SelectionLensRule.material(for: appearance, reduceTransparency: reduceTransparency) != .today
    }

    /// The surface `elapsed` seconds into opening, inside `bounds`: the lens's move
    /// (`SelectionLensMotion.frame`) from a square pill at the trailing edge to the whole field, so
    /// the leading edge springs out, overshoots a little and settles while the magnifier's end
    /// stays put.
    ///
    /// `rowHeight` is the first row with its padding. Accessories can grow the field below it
    /// mid-opening (suggestions appear once the field takes the caret), so a pill sized from the
    /// whole field would jump; sized from the row, it grows down into them instead.
    public static func surfaceFrame(in bounds: CGRect, rowHeight: CGFloat? = nil,
                                    elapsed: TimeInterval) -> SelectionLensMotion.Frame {
        let height = min(bounds.height, rowHeight ?? bounds.height)
        let side = min(bounds.width, height)
        let pill = CGRect(x: bounds.maxX - side, y: bounds.minY, width: side, height: height)
        let rect = SelectionLensMotion.frame(from: pill, to: bounds, elapsed: elapsed)?.rect ?? bounds
        return .init(rect: rect, opacity: SelectionLensMotion.clamp(elapsed / surfaceFade))
    }

    /// How long the pill takes to become opaque as it starts out.
    static let surfaceFade: TimeInterval = 0.08

    /// The query, its clear button and accessories: invisible for 0.12 s, then in over 0.15 s. By
    /// 0.12 s the leading edge has covered most of the field, so the query appears into room.
    public static func contentOpacity(elapsed: TimeInterval) -> Double {
        SelectionLensMotion.clamp((elapsed - 0.12) / 0.15)
    }
}

/// Whether a field was inserted by an animated transaction, answered once by the first
/// transaction to reach it (which arrives before `onAppear`). A reference type so recording it
/// doesn't re-render the field.
final class ExpandingSearchInsertion {
    var wasAnimated: Bool?
}

private struct ExpandingSearchTimeScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private struct ExpandingSearchFrozenElapsedKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}

/// The field's first row, so its surface can open out of a pill that row's height.
private struct ExpandingSearchRowKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension EnvironmentValues {
    /// How much slower than real time the field travels open. Always 1 in the app; a test can
    /// stretch it, since a busy main thread in a parallel run can outlast a sub-second travel.
    var expandingSearchTimeScale: Double {
        get { self[ExpandingSearchTimeScaleKey.self] }
        set { self[ExpandingSearchTimeScaleKey.self] = newValue }
    }

    /// Holds an opening field at this many seconds in. nil in the app; a test sets it to render one
    /// instant of the travel exactly instead of sampling a live one.
    var expandingSearchFrozenElapsed: TimeInterval? {
        get { self[ExpandingSearchFrozenElapsedKey.self] }
        set { self[ExpandingSearchFrozenElapsedKey.self] = newValue }
    }
}

/// The magnifier that reveals the field: the last item of its host's controls row, where
/// Compare's `standardHeaderControls` puts it.
public struct ExpandingSearchToggle: View {
    @Binding private var text: String
    @Binding private var isExpanded: Bool
    private let accent: Color
    private let help: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - text: the live query. Cleared when the toggle collapses the field.
    ///   - isExpanded: whether the field is showing. Host-owned so the host can size around it.
    ///   - accent: the tint worn while the field is open or a query is live.
    ///   - help: the tooltip and the accessibility label. Name what this lens searches, since that
    ///     differs per surface.
    public init(text: Binding<String>, isExpanded: Binding<Bool>, accent: Color, help: String) {
        self._text = text
        self._isExpanded = isExpanded
        self.accent = accent
        self.help = help
    }

    public var body: some View {
        Button {
            withDesignAnimation(ExpandingSearch.animation, reduceMotion: reduceMotion) {
                isExpanded.toggle()
                if !isExpanded { text = "" }
            }
        } label: {
            // Padded so the hover wash has room around a 13pt glyph, then pulled back below so the
            // footprint is unchanged (TokenChipsRow's idiom).
            Image(systemName: "magnifyingglass")
                .padding(5)
                .contentShape(Rectangle())
        }
        // Frosted and Clear: a glass circle with a round hover, like every bar button
        // (`ChromeGlass`), on the padded button before the padding below takes it back.
        .chromeGlassGlyphButton(tint: accent)
        .padding(-5)
        // Tints while the field is open or a query is live, so a filter can't hide behind a
        // quiet, collapsed glyph.
        .foregroundStyle((isExpanded || !text.isEmpty) ? accent : Color.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The revealed field: the query, a clear button, an optional trailing slot, and an optional
/// accessories area below (chips, one-tap suggestions) that shares the field's surface.
///
/// Escape collapses and clears. Focus is claimed here, on appear — see the note on `body`.
public struct ExpandingSearchField<Trailing: View, Accessories: View>: View {
    @Binding private var text: String
    @Binding private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let placeholder: String
    private let trailing: () -> Trailing
    private let accessories: (Bool) -> Accessories

    @FocusState private var focused: Bool
    @Environment(\.selectionLensAppearance) private var lensAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.expandingSearchTimeScale) private var timeScale
    @Environment(\.expandingSearchFrozenElapsed) private var frozenElapsed
    @State private var insertion = ExpandingSearchInsertion()
    /// When the field began travelling open; nil at rest. See `ExpandingSearch.surfaceFrame`.
    @State private var openedAt: Date?

    /// - Parameters:
    ///   - placeholder: this lens's vocabulary, the only thing teaching which tokens bind here, so
    ///     it must advertise exactly the tokens this surface's grammar declares (see `LensSearch`).
    ///   - trailing: content inside the field row, after the clear button (Compare's "N of M").
    ///   - accessories: content below the field row, inside the same surface. Receives whether
    ///     the field holds the caret, for suggestions that only show while focused.
    public init(
        text: Binding<String>,
        isExpanded: Binding<Bool>,
        placeholder: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder accessories: @escaping (Bool) -> Accessories = { _ in EmptyView() }
    ) {
        self._text = text
        self._isExpanded = isExpanded
        self.placeholder = placeholder
        self.trailing = trailing
        self.accessories = accessories
    }

    private var travels: Bool {
        ExpandingSearch.travels(appearance: lensAppearance, reduceTransparency: reduceTransparency,
                                reduceMotion: reduceMotion)
    }

    public var body: some View {
        // The frame clock ticks only while the field travels open; at rest and in Solid it is
        // paused. It wraps the field in every appearance, and the surface draws in a background,
        // not a branch, so the field's identity (and its caret) never depends on the setting.
        TimelineView(AnimationTimelineSchedule(minimumInterval: nil, paused: openedAt == nil)) { context in
            let elapsed = openedAt.map { frozenElapsed ?? context.date.timeIntervalSince($0) / timeScale }
                ?? SelectionLensMotion.travelDuration
            field
                .opacity(openedAt == nil ? 1 : ExpandingSearch.contentOpacity(elapsed: elapsed))
                .modifier(ExpandingSearchSurface(travels: travels, elapsed: elapsed,
                                                 drawsProbe: lensAppearance.drawsProbe))
        }
        .transaction { transaction in
            if insertion.wasAnimated == nil { insertion.wasAnimated = transaction.animation != nil }
        }
        .onAppear {
            // Spent on every appearance, glass or not: an `onAppear` that fires again without the
            // field being re-created (a lazy container re-attaching it) must not replay an opening,
            // including one made at Solid before the setting changed.
            let animated = insertion.wasAnimated == true
            insertion.wasAnimated = false
            guard travels, animated else { return }
            let start = Date()
            openedAt = start
            // Not `.task(id:)`: a task started on a field mid-insertion is cancelled at once, and a
            // cancelled sleep would end the travel before its first frame.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(SelectionLensMotion.travelDuration * timeScale))
                if openedAt == start { openedAt = nil }
            }
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    // The placeholder teaches the lens's search words and vanishes at the first
                    // keystroke; the tooltip keeps it a hover away.
                    .help(placeholder)
                    .focused($focused)
                    // Focus is claimed here, once the field exists, never by the toggle: a
                    // FocusState write in the transaction that inserts the field is silently
                    // dropped. The one-turn Task hop outlives it. Moved into the toggle, the field
                    // would reveal unfocused.
                    .onAppear { Task { @MainActor in focused = true } }
                    .onExitCommand {
                        ExpandingSearch.collapse(text: $text, isExpanded: $isExpanded,
                                                 reduceMotion: reduceMotion)
                    }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
                trailing()
            }
            .anchorPreference(key: ExpandingSearchRowKey.self, value: .bounds) { $0 }
            accessories(focused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// The field's surface: `searchFieldSurface()`'s wash, in a background so the field is never in a
/// branch. Where the field doesn't travel, the wash fills its bounds; where it does, the wash takes
/// the frame `ExpandingSearch.surfaceFrame` gives at `elapsed`, the whole field once open.
private struct ExpandingSearchSurface: ViewModifier {
    let travels: Bool
    let elapsed: TimeInterval
    let drawsProbe: Bool

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(ExpandingSearchRowKey.self) { row in
            if travels {
                GeometryReader { proxy in
                    // The row's bottom plus the field's 6pt below it: the pill a closed field
                    // would be.
                    let rowHeight = row.map { proxy[$0].maxY + 6 }
                    let frame = ExpandingSearch.surfaceFrame(in: CGRect(origin: .zero, size: proxy.size),
                                                             rowHeight: rowHeight, elapsed: elapsed)
                    Group {
                        // The probe (tests only) paints the surface magenta so its travel can be
                        // measured; the wash is too faint.
                        if drawsProbe {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(SelectionLensRule.probeColor)
                        } else {
                            SearchFieldWash()
                        }
                    }
                    .frame(width: max(0, frame.rect.width), height: max(0, frame.rect.height))
                    .offset(x: frame.rect.minX, y: frame.rect.minY)
                    .opacity(frame.opacity)
                }
            } else {
                SearchFieldWash()
            }
        }
    }
}
