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

    public init(title: String, completed: Int64 = 0, total: Int64 = 0, detail: String? = nil,
                cancelTitle: String = "Cancel", cancelHelp: String = "Cancel operation",
                note: String? = nil) {
        self.title = title
        self.completed = completed
        self.total = total
        self.detail = detail
        self.cancelTitle = cancelTitle
        self.cancelHelp = cancelHelp
        self.note = note
    }

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
public struct ProgressCapsule: View {
    let run: ProgressCapsuleRun
    let style: ProgressCapsuleStyle
    /// How many other runs are going behind this one — shown as "+1", named in the tooltip.
    let othersRunning: [String]
    let onCancel: (() -> Void)?

    @State private var hovering = false
    /// The window's hue for the ring's arc — a line, so the raw accent, not the system's `.tint`.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    public init(run: ProgressCapsuleRun, style: ProgressCapsuleStyle,
                othersRunning: [String] = [], onCancel: (() -> Void)?) {
        self.run = run
        self.style = style
        self.othersRunning = othersRunning
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 8) {
            ring
            if style == .full {
                // The file in hand while the pointer is over it; the run's own words otherwise.
                Text(run.note ?? (hovering ? (run.detail ?? run.title) : run.title))
                    .scaledFont(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProgressView(value: run.fraction, total: 1)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: ProgressCapsuleMetrics.barWidth)
                if run.total > 0 {
                    Text(Self.formattedCount(completed: run.completed, total: run.total))
                        .scaledFont(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if !othersRunning.isEmpty {
                Text("+\(othersRunning.count)")
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline))
                // ⌘. and deliberately not esc (see `AppChord.cancelOperation`).
                .keyboardShortcut(AppChord.cancelOperation.key, modifiers: AppChord.cancelOperation.modifiers)
                .help(ShortcutHint.tooltip(run.cancelHelp, AppChord.cancelOperation.display))
                .accessibilityLabel(run.cancelTitle)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(width: style == .full ? ProgressCapsuleMetrics.fullWidth : ProgressCapsuleMetrics.ringWidth,
               height: ProgressCapsuleMetrics.height)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        ([run.summary] + othersRunning).joined(separator: "\n")
    }

    /// Determinate while the run can count, a spinner while it cannot.
    @ViewBuilder private var ring: some View {
        if let fraction = run.fraction {
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
