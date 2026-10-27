import SwiftUI

/// One run, as the toolbar's progress capsule draws it — a snapshot, taken again on every tick by
/// whoever hosts the capsule, since an `NSProgress` is not observable.
public struct ProgressCapsuleRun: Equatable, Sendable {
    /// "Merging “Photos”" — the run's own description.
    public var title: String
    public var completed: Int64
    /// `0` for a run that cannot count: the capsule spins instead of filling.
    public var total: Int64
    /// The file in hand, shown in place of the title while the pointer is over the capsule.
    public var detail: String?
    /// "Cancel", or "Stop" for a run whose finished part stays.
    public var cancelTitle: String
    /// What the stop button's tooltip says it does.
    public var cancelHelp: String
    /// A sentence said over the run for a moment — a second request refused while this one runs.
    public var note: String?
    /// Nothing is running: the capsule stays only because Activity hangs from it (TE231), so it
    /// neither spins nor fills.
    public var isIdle: Bool

    public init(title: String, completed: Int64 = 0, total: Int64 = 0, detail: String? = nil,
                cancelTitle: String = "Cancel", cancelHelp: String = "Cancel operation",
                note: String? = nil, isIdle: Bool = false) {
        self.title = title
        self.completed = completed
        self.total = total
        self.detail = detail
        self.cancelTitle = cancelTitle
        self.cancelHelp = cancelHelp
        self.note = note
        self.isIdle = isIdle
    }

    /// The capsule with nothing in it, while Activity is open under it.
    public static let idle = ProgressCapsuleRun(title: "Nothing running", isIdle: true)

    /// An `NSProgress` as the capsule reads it: its description, its counts, its current item.
    public init(progress: Progress) {
        self.init(title: progress.localizedDescription ?? "Processing…",
                  completed: progress.completedUnitCount,
                  total: progress.totalUnitCount,
                  detail: progress.localizedAdditionalDescription.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// 0…1, or `nil` when there is nothing to count. Clamped: `completed` can drift past `total`
    /// during a cancel, and an out-of-range value makes `ProgressView` warn and pin oddly.
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// "Merging “Photos” · 3,336 of 7,363 · IMG_2034.jpg" — everything the capsule knows, for the
    /// tooltip and VoiceOver, which see the ring alone at narrow widths.
    public var summary: String {
        var parts = [note ?? title]
        if total > 0 { parts.append(ProgressCapsule.formattedCount(completed: completed, total: total)) }
        if let detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

/// **A message in the capsule** (Run Room CG, TE233): the ending of a run that finished after the
/// reader moved on, which the window shows here rather than in a pane they are not looking at.
public struct ProgressCapsuleMessage {
    public enum Weight: Equatable, Sendable {
        case success, warning, failure
    }

    /// A button beside the words: Undo, Reveal in Browse, Open in Edit.
    public struct Action: Identifiable {
        public let id: String
        public var title: String
        public var help: String
        public var isEnabled: Bool
        public var perform: () -> Void

        public init(title: String, help: String, isEnabled: Bool = true, perform: @escaping () -> Void) {
            id = title
            self.title = title
            self.help = help
            self.isEnabled = isEnabled
            self.perform = perform
        }
    }

    public var text: String
    public var weight: Weight
    public var actions: [Action]
    public var onClose: () -> Void
    /// The pointer over the capsule holds the message, as over a pane's.
    public var onHover: (Bool) -> Void

    public init(text: String, weight: Weight, actions: [Action] = [], onClose: @escaping () -> Void,
                onHover: @escaping (Bool) -> Void = { _ in }) {
        self.text = text
        self.weight = weight
        self.actions = actions
        self.onClose = onClose
        self.onHover = onHover
    }
}

/// How much of the toolbar the capsule has — decided by the toolbar's width ladder, never by the
/// capsule (`WorkspaceBarMetrics`).
public enum ProgressCapsuleStyle: Equatable, Sendable {
    /// Ring, title, bar, count and stop button.
    case full
    /// The ring and the stop button; the rest is in the tooltip (TE206).
    case ring
}

/// The capsule's two widths, fixed so the toolbar's arithmetic can charge them exactly: a toolbar
/// item that grows past what was reserved for it is folded behind the overflow chevron, and the
/// stop button with it.
public enum ProgressCapsuleMetrics {
    public static let fullWidth: CGFloat = 380
    public static let ringWidth: CGFloat = 60
    static let height: CGFloat = 28
    static let barWidth: CGFloat = 72
    static let ringSide: CGFloat = 16
}

/// **A long run's progress, in the middle of the toolbar** (TE205, decision BY). It replaced the
/// centred dialog whose dimming took every click until the run ended (TE208): the window stays
/// usable for reading while the run goes on, and only the actions that write wait (decision BZ).
///
/// The stop button keeps the dialog's chord, ⌘. — and deliberately not Esc, since the whole window
/// is live around it and Esc clears a pane's selection (`AppChord.cancelOperation`).
///
/// **With two or more runs the stop button gives way to a count, "2 ⌄"** (TE218, TE219): the
/// capsule draws the newest run, and a ✕ there would stop whichever run happened to be drawn —
/// which changes under the pointer when one ends. The count opens the list where each run has its
/// own Stop, and takes ⌘. with it (decision CJ: the key opens the list, never stops a run unseen).
public struct ProgressCapsule: View {
    let run: ProgressCapsuleRun
    let style: ProgressCapsuleStyle
    /// The other runs going beside this one, newest first — counted on the button, named in the
    /// tooltip.
    let othersRunning: [String]
    let onCancel: (() -> Void)?
    /// Opens the list of every run — the count button's action, and ⌘.'s, while others run.
    let onShowRuns: (() -> Void)?
    /// A click anywhere else on the capsule: opens Activity (TE220).
    let onOpen: (() -> Void)?
    /// A message taking the capsule for its five seconds, over any run (decision CU): its words in
    /// the run's place, ✓ or ✕ in the ring, and the count still saying how many runs go on.
    let message: ProgressCapsuleMessage?

    @State private var hovering = false
    /// The window's hue for the ring's arc — a line, so the raw accent, not the system's `.tint`.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    public init(run: ProgressCapsuleRun, style: ProgressCapsuleStyle,
                othersRunning: [String] = [], onCancel: (() -> Void)?,
                onShowRuns: (() -> Void)? = nil, onOpen: (() -> Void)? = nil,
                message: ProgressCapsuleMessage? = nil) {
        self.run = run
        self.style = style
        self.othersRunning = othersRunning
        self.onCancel = onCancel
        self.onShowRuns = onShowRuns
        self.onOpen = onOpen
        self.message = message
    }

    /// What the trailing button does: stop the one run, or open the list of several. Never both,
    /// so the capsule registers ⌘. once.
    enum Trailing: Equatable {
        case stop
        case count(Int)
        case none
    }

    var trailing: Trailing {
        // Over a message the runs go on behind it: a count — even of one — says so, and opens them.
        if message != nil {
            return run.isIdle || onShowRuns == nil ? .none : .count(othersRunning.count + 1)
        }
        if !othersRunning.isEmpty, onShowRuns != nil { return .count(othersRunning.count + 1) }
        return onCancel == nil ? .none : .stop
    }

    public var body: some View {
        HStack(spacing: 8) {
            ring
            if let message, style == .full {
                Text(message.text)
                    .scaledFont(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(message.actions.prefix(2)) { action in
                    Button(action.title, action: action.perform)
                        .buttonStyle(.hoverAffordance(.inline))
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .disabled(!action.isEnabled)
                        .help(action.help)
                        .fixedSize()
                }
            } else if style == .full {
                // The file in hand while the pointer is over it; the run's own words otherwise.
                Text(run.note ?? (hovering ? (run.detail ?? run.title) : run.title))
                    .scaledFont(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !run.isIdle {
                    ProgressView(value: run.fraction, total: 1)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: ProgressCapsuleMetrics.barWidth)
                }
                if run.total > 0 {
                    Text(Self.formattedCount(completed: run.completed, total: run.total))
                        .scaledFont(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if trailing != .none {
                Button(action: { trailingAction() }) {
                    trailingLabel
                }
                .buttonStyle(.hoverAffordance(.inline))
                // ⌘. and deliberately not esc (see `AppChord.cancelOperation`).
                .keyboardShortcut(AppChord.cancelOperation.key, modifiers: AppChord.cancelOperation.modifiers)
                .help(ShortcutHint.tooltip(trailingHelp, AppChord.cancelOperation.display))
                .accessibilityLabel(trailingAccessibilityLabel)
            } else if let message, style == .full {
                // No key: ⌘. stops runs, and there is none here.
                Button(action: message.onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline))
                .help("Close the message — it stays in Activity")
                .accessibilityLabel("Close message")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(width: style == .full ? ProgressCapsuleMetrics.fullWidth : ProgressCapsuleMetrics.ringWidth,
               height: ProgressCapsuleMetrics.height)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .contentShape(Capsule())
        // The stop and the count are buttons of their own and keep their clicks.
        .onTapGesture { onOpen?() }
        .onHover { inside in
            hovering = inside
            message?.onHover(inside)
        }
        .help(tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Show Activity") { onOpen?() }
    }

    /// Every run, newest first, one to a line — and the count ahead of them for VoiceOver, which
    /// hears the capsule as one element (TE226).
    private var tooltip: String {
        let runs = run.isIdle && message != nil ? [] : [run.summary] + othersRunning
        return ([message?.text].compactMap { $0 } + runs).joined(separator: "\n")
    }

    private var accessibilityText: String {
        let said = message.map { [$0.text] } ?? []
        guard case .count(let count) = trailing else { return tooltip }
        return (said + ["Activity, \(count) running"] + [run.summary] + othersRunning).joined(separator: ". ")
    }

    private func trailingAction() {
        switch trailing {
        case .stop: onCancel?()
        case .count: onShowRuns?()
        case .none: break
        }
    }

    private var trailingHelp: String {
        guard case .count(let count) = trailing else { return run.cancelHelp }
        return "\(count) running — show each with its own Stop"
    }

    private var trailingAccessibilityLabel: String {
        guard case .count(let count) = trailing else { return run.cancelTitle }
        return "\(count) running, show each"
    }

    /// The ✕, or the count: "2 ⌄" in the full capsule, a filled badge in the ring, where the
    /// chevron has no room (TE225).
    @ViewBuilder private var trailingLabel: some View {
        switch trailing {
        case .count(let count) where style == .full:
            HStack(spacing: 2) {
                Text("\(count)")
                    .scaledFont(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .padding(.leading, 6)
            .padding(.trailing, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.background))
            .overlay(Capsule().strokeBorder(.separator))
            .fixedSize()
        case .count(let count):
            let hue = LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
            Text("\(count)")
                .scaledFont(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(hue.onAccentLabelColor)
                .frame(minWidth: 15, minHeight: 15)
                .background(Circle().fill(hue.accentFillColor))
                .fixedSize()
        default:
            Image(systemName: "xmark.circle.fill")
                .hoverInk()
        }
    }

    /// Determinate while the run can count, a spinner while it cannot.
    @ViewBuilder private var ring: some View {
        if let message {
            Image(systemName: Self.symbol(message.weight))
                .font(.system(size: 14))
                .foregroundStyle(Self.tint(message.weight))
                .frame(width: ProgressCapsuleMetrics.ringSide, height: ProgressCapsuleMetrics.ringSide)
                .accessibilityHidden(true)
        } else if run.isIdle {
            Circle().stroke(.quaternary, lineWidth: 2.5)
                .frame(width: ProgressCapsuleMetrics.ringSide, height: ProgressCapsuleMetrics.ringSide)
                .accessibilityHidden(true)
        } else if let fraction = run.fraction {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke((LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: ProgressCapsuleMetrics.ringSide, height: ProgressCapsuleMetrics.ringSide)
            .accessibilityHidden(true)
        } else {
            InlineSpinner()
        }
    }

    static func symbol(_ weight: ProgressCapsuleMessage.Weight) -> String {
        switch weight {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    static func tint(_ weight: ProgressCapsuleMessage.Weight) -> Color {
        switch weight {
        case .success: return SemanticColor.success
        case .warning: return SemanticColor.warning
        case .failure: return SemanticColor.error
        }
    }

    /// "3,336 of 7,363", grouped the way the reader's locale writes numbers — read each time, as
    /// the title's `CountedNoun` is. A cached `NumberFormatter` with no locale set kept the region
    /// it was first used in, so a region change left the counter grouped one way under a title
    /// grouped another.
    /// - Parameter locale: the reader's unless a test pins one.
    nonisolated static func formattedCount(completed: Int64, total: Int64,
                                           locale: Locale = .autoupdatingCurrent) -> String {
        // Clamp the shown count to the total for the same reason the bar is clamped: `completed`
        // can briefly drift past `total` during cancel, which would otherwise read like
        // "7,400 of 7,363".
        let shown = total > 0 ? min(completed, total) : completed
        let style = IntegerFormatStyle<Int64>.number.locale(locale)
        return "\(shown.formatted(style)) of \(total.formatted(style))"
    }
}
