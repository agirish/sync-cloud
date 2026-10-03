import SwiftUI

/// The app's one expand-on-demand search container: a magnifier that reveals a field, the field
/// itself, and the focus / Escape / clear behaviour that ties the two together.
///
/// This mechanism existed only inside `DifferencesView` (Compare) — Organize's Duplicates search
/// shared the *grammar* (`TokenQuery`) but had an always-visible compact field with no expansion
/// and no Escape. Every surface with a token search drives this now, so "search behaves the same
/// everywhere" holds by construction instead of by two copies happening to agree.
///
/// The toggle and the field are separate views because they sit on different rows of their host:
/// the toggle rides the controls row (last item, far right), the field appears below it. They
/// share `text` and `isExpanded`, which the host owns.
public enum ExpandingSearch {
    /// The reveal/collapse animation. One constant, so the toggle and any host layout that keys
    /// off `isExpanded` (a card growing to fit the field) move as one.
    public static let animation: Animation = .easeOut(duration: 0.15)

    /// Collapses and clears in one animated transaction — what Escape and the toggle's second
    /// click both do. Clearing on collapse is deliberate: a query left live behind a hidden field
    /// is a filter you can't see or undo.
    ///
    /// `reduceMotion` has no default on purpose: a defaulted `false` is how three of this
    /// component's four hosts came to animate the reveal with the setting on, and a default is
    /// exactly what stops a caller noticing it has a decision to make.
    public static func collapse(text: Binding<String>, isExpanded: Binding<Bool>, reduceMotion: Bool) {
        withDesignAnimation(animation, reduceMotion: reduceMotion) {
            text.wrappedValue = ""
            isExpanded.wrappedValue = false
        }
    }

    // MARK: Opening in glass (RD46.10)
    //
    // Solid — and Reduce Transparency, and Reduce Motion — keeps today's opening: the field fades
    // in on the host's transition. In Frosted and Clear the field's surface TRAVELS out of the
    // magnifier's end of the row, the way a selection lens travels: it starts as a magnifier-sized
    // pill at the trailing edge and springs out to the full width on the lens's own springs, with
    // the same small overshoot. The query fades in once there is room for it.
    // Closing is today's fade in every appearance.
    //
    // The surface itself is unchanged — the same wash every search field in the app wears. Glass
    // changes how it opens, not what it is.
    //
    // **Only an animated insertion travels** — which is what the magnifier and ⌘F both make. A
    // view that comes back with a search already open (a workspace switch animates only its own
    // bar) inserts the field without animation, and the field is simply there, at rest.
    //
    // **Why the field runs its own clock rather than being given a transition.** Measured while
    // building this: a `Transition`'s modifiers animate, but nothing they write reaches the view
    // inside — an environment value set there, even a constant one, is never read by the field —
    // so a transition can fade the field but cannot travel its surface. The field reads the
    // transaction that inserted it instead, and draws the travel on a frame clock, which is also
    // how the lens draws its own.

    /// Whether the field opens by travelling rather than fading.
    public static func travels(appearance: SelectionLensAppearance, reduceTransparency: Bool,
                               reduceMotion: Bool) -> Bool {
        !reduceMotion
            && SelectionLensRule.material(for: appearance, reduceTransparency: reduceTransparency) != .today
    }

    /// The surface `elapsed` seconds into opening, inside `bounds`: a lens travelling from a pill
    /// as wide as the field's first row is tall, at the trailing edge, to the whole field — the
    /// lens's own move (`SelectionLensMotion.frame`), so the leading edge springs out, overshoots a
    /// little and settles once, while the magnifier's end stays put.
    ///
    /// `rowHeight` is that first row, with its padding: the field's accessories grow it below the
    /// row while it opens — a host's suggestions appear once the field takes the caret, one turn in —
    /// and a pill sized from the whole field jumped from 28pt to 51pt part-way. Sized from the row,
    /// the surface opens out of the magnifier and grows down into the suggestions as they arrive.
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

    /// The query, its clear button and the field's accessories: invisible for the first 0.12 s, then
    /// in over 0.15 s — the approved mockup's numbers. By 0.12 s the leading edge has covered most of
    /// the field, so the query appears into room that is already there.
    public static func contentOpacity(elapsed: TimeInterval) -> Double {
        SelectionLensMotion.clamp((elapsed - 0.12) / 0.15)
    }
}

/// Whether a field was inserted by an animated transaction — answered once, by the first
/// transaction to reach it, which arrives before `onAppear`. A reference type so that recording
/// the answer does not itself re-render the field.
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
    /// How much slower than real time the field travels open. Always 1 in the app; internal so a
    /// test can stretch it — sampling a sub-second travel from a test is at the mercy of whatever
    /// else holds the main thread, and a full parallel run held it for longer than the travel lasts.
    var expandingSearchTimeScale: Double {
        get { self[ExpandingSearchTimeScaleKey.self] }
        set { self[ExpandingSearchTimeScaleKey.self] = newValue }
    }

    /// Holds an opening field at this many seconds in, however long it has really been. nil in the
    /// app; a test sets it to render one instant of the travel exactly, rather than sampling a live
    /// one and hoping a busy main thread let it see the instant it asks about.
    var expandingSearchFrozenElapsed: TimeInterval? {
        get { self[ExpandingSearchFrozenElapsedKey.self] }
        set { self[ExpandingSearchFrozenElapsedKey.self] = newValue }
    }
}

/// The magnifier that reveals the field — the last item of its host's controls row, mirroring
/// where Compare's `standardHeaderControls` puts it.
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
    ///   - help: the tooltip AND the accessibility label — it should name what this lens
    ///     searches, since that differs per surface.
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
            // Padded out so the hover wash has room around a 13pt glyph, then pulled back below
            // so the toggle's footprint in the header is unchanged (TokenChipsRow's idiom).
            Image(systemName: "magnifyingglass")
                .padding(5)
                .contentShape(Rectangle())
        }
        // Frosted and Clear: a glass circle with a round hover, like every bar button
        // (`ChromeGlass`) — on the padded button, before the padding below takes the footprint back.
        .chromeGlassGlyphButton(tint: accent)
        .padding(-5)
        // Tints whenever the field is open OR a query is live — so a filter narrowing the list
        // can never be silently on behind a quiet, collapsed glyph.
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
    ///   - placeholder: this lens's vocabulary. It is the ONLY thing teaching which tokens bind
    ///     here, so it must advertise exactly the tokens this surface's grammar declares and no
    ///     others (see the per-lens grammar note in `LensSearch`).
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
        // The frame clock ticks only while the field travels open — at rest, and always in Solid,
        // it is paused and costs nothing. It wraps the field in every appearance, and the surface
        // below draws in a background rather than wrapping the field in a branch, so the field's
        // identity — and with it the caret — never depends on the setting.
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
            // field being re-created (a lazy container re-attaching it) must not replay an opening
            // nobody asked for — including one made at Solid before the setting changed.
            let animated = insertion.wasAnimated == true
            insertion.wasAnimated = false
            guard travels, animated else { return }
            let start = Date()
            openedAt = start
            // Not `.task(id:)`: measured, a task started on a field mid-insertion is cancelled at
            // once, and a cancelled sleep would end the travel before its first frame.
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
                    .focused($focused)
                    // Focus is claimed HERE, once the field exists — never by the toggle that
                    // reveals it. A FocusState write landing in the same transaction that
                    // inserts the field is silently dropped; the one-turn Task hop outlives that
                    // transaction. This is load-bearing: inline it back into the toggle and the
                    // field reveals unfocused, so you have to click it before typing.
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

/// The field's surface: the wash `searchFieldSurface()` draws, in a background so the field itself
/// is never inside a branch. At Solid (and under Reduce Transparency or Reduce Motion) it is that
/// wash on the field's own bounds, pixel for pixel; where the field opens by travelling it is the
/// same wash on the frame `ExpandingSearch.surfaceFrame` gives `elapsed` seconds into opening —
/// the whole field once the opening is over.
private struct ExpandingSearchSurface: ViewModifier {
    let travels: Bool
    let elapsed: TimeInterval
    let drawsProbe: Bool

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(ExpandingSearchRowKey.self) { row in
            if travels {
                GeometryReader { proxy in
                    // The row's bottom plus the field's own 6pt below it — the pill a closed field
                    // would be.
                    let rowHeight = row.map { proxy[$0].maxY + 6 }
                    let frame = ExpandingSearch.surfaceFrame(in: CGRect(origin: .zero, size: proxy.size),
                                                             rowHeight: rowHeight, elapsed: elapsed)
                    Group {
                        // The probe (tests only) paints the surface magenta, so its travel can be
                        // measured; today's wash is too faint to. Otherwise it IS today's wash.
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
