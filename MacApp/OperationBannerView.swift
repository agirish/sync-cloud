import AppKit
import SwiftUI
import Sync
import Design

/// The result message: what the operation you just ran did. Beyond the message + close button, an
/// undoable outcome (`banner.isUndoable`, and the undo stack still has it on top) gets a one-click
/// **Undo** — the visible face of the ⌘Z that already works — a finished file gets its doors
/// (`banner.followUps`: Open in Edit, Reveal in Browse, Download), and auto-dismissing severities get
/// a thin countdown bar so the disappearing window is legible.
///
/// **It lives in the pane, not over the window** (Banner Room, CA). It used to float across the
/// window's top for five seconds, over the pane header's Delete — the button the next click was
/// aimed at. Now each pane's file list docks it in one stack with the contextual action bar, at the
/// edge `PaneBarPlacement` picks, so it covers neither the bar, the header nor the row acted on.
///
/// A struct (not a `@ViewBuilder` on ContentView) so it can hold the countdown `@State`. The
/// auto-dismiss timing itself still lives in `BannerDismissScheduler`; the bar only mirrors it,
/// reading the same `Delays.standard` window so the two never disagree on how long is left, and
/// resetting to full on hover exactly as the scheduler restarts its timer.
struct OperationBannerView: View {
    let banner: OperationBanner
    let glassLevel: GlassLevel
    /// Whether the undo stack currently has something to undo. Combined with `banner.isUndoable`
    /// (the outcome is a single undo step) to decide whether to offer the button — so a banner
    /// whose operation has already been undone elsewhere doesn't show a dead Undo.
    let canUndo: Bool
    let onUndo: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    /// Performs one of `banner.followUps`.
    var onFollowUp: (OperationBanner.FollowUp) -> Void = { _ in }
    /// A control the surface showing the message adds after its own — To File's "Save as rule…".
    var accessory: AnyView? = nil

    @State private var countdown: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The auto-dismiss window for this severity, in seconds, or nil when the banner is sticky
    /// (errors). Read straight from the scheduler's delays so the bar can never drift from the
    /// real timer.
    var autoDismissSeconds: Double? {
        BannerDismissScheduler.Delays.standard
            .delayNanoseconds(for: banner.severity)
            .map { Double($0) / 1_000_000_000 }
    }

    /// Whether to offer the one-click Undo. Both halves are load-bearing: `isUndoable` says the
    /// outcome is a single undo step, `canUndo` says the stack still has it — dropping either
    /// shows a dead button (already-undone elsewhere) or hides a live one. Instance state +
    /// injected flag, so the truth table is testable on a constructed view; `body` reads this
    /// property and nothing else for the decision.
    var showsUndo: Bool { banner.isUndoable && canUndo }

    /// The countdown-bar rule, static so the Reduce Motion arm is testable — the environment
    /// value cannot be injected into a constructed struct outside a render.
    static func showsCountdown(autoDismissSeconds: Double?, reduceMotion: Bool) -> Bool {
        autoDismissSeconds != nil && !reduceMotion
    }

    private var showsCountdown: Bool {
        Self.showsCountdown(autoDismissSeconds: autoDismissSeconds, reduceMotion: reduceMotion)
    }

    private var tint: Color { OperationBannerStyle.tint(for: banner.severity) }

    /// A follow-up's button title — the words the PDF tools' own banner used for the same doors.
    static func title(for followUp: OperationBanner.FollowUp) -> String {
        switch followUp {
        case .openInEdit: return "Open in Edit"
        case .revealInBrowse: return "Reveal in Browse"
        case .download: return "Download"
        }
    }

    /// Its tooltip, naming the file — or how many — it goes to.
    static func help(for followUp: OperationBanner.FollowUp) -> String {
        func name(_ path: String) -> String { "“\((path as NSString).lastPathComponent)”" }
        switch followUp {
        case .openInEdit(let path): return "Open \(name(path)) in Edit"
        case .revealInBrowse(let paths):
            return paths.count == 1 ? "Show \(name(paths[0])) in Browse" : "Show the \(paths.count) files in Browse"
        case .download: return "Download the file from the cloud, then try again"
        }
    }

    /// **What VoiceOver hears when the message appears** (TE211): the message, and — when the Undo
    /// button shows — that ⌘Z takes it back. Nothing announced it before: "Deleted “Test3.md”" and
    /// its Undo were silent.
    static func announcement(for banner: OperationBanner, offersUndo: Bool) -> String {
        guard offersUndo else { return banner.message }
        let ends = banner.message.last.map { ".!?".contains($0) } ?? false
        return banner.message + (ends ? " " : ". ") + "Undo available, Command Z"
    }

    /// Posts the announcement. High priority, so it is spoken over whatever VoiceOver was reading —
    /// the click that caused it.
    static func announce(_ banner: OperationBanner, offersUndo: Bool) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: (app.mainWindow as NSResponder?) ?? app,
                             notification: .announcementRequested,
                             userInfo: [.announcement: announcement(for: banner, offersUndo: offersUndo),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One row while the words and buttons fit; in a narrow pane the words wrap and the
            // buttons drop under them, so nothing is truncated away.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    icon
                    words
                    Spacer(minLength: 8)
                    buttons
                    close
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon
                        words.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        close
                    }
                    if hasButtons {
                        HStack(spacing: 6) { buttons }
                            .fixedSize()
                    }
                }
            }

            if showsCountdown {
                GeometryReader { geo in
                    Capsule()
                        .fill(tint.opacity(0.5))
                        .frame(width: max(0, geo.size.width * countdown), alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassCardStyle(level: glassLevel)
        .onAppear { startCountdown() }
        .onHover { hovering in
            onHover(hovering)
            guard showsCountdown else { return }
            if hovering {
                // Mirror the scheduler: hovering earns the banner a fresh full window, so show the
                // bar full (paused) rather than trying to freeze mid-animation.
                withAnimation(.easeOut(duration: 0.15)) { countdown = 1 }
            } else {
                startCountdown()
            }
        }
    }

    private var icon: some View {
        Image(systemName: OperationBannerStyle.iconName(for: banner.severity))
            .scaledFont(.title3)
            .foregroundStyle(tint)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(banner.message)
                .scaledFont(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            if let detail = banner.detail {
                Text(detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var hasButtons: Bool { showsUndo || !banner.followUps.isEmpty || accessory != nil }

    @ViewBuilder
    private var buttons: some View {
        if showsUndo {
            Button(action: onUndo) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                }
                .scaledFont(.subheadline.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: tint))
            .shortcutKeycap("⌘Z")
            // Greyed while a long run is going, as ⌘Z is (Banner Room, CF): a message up when a
            // run starts keeps its button, greyed, and has it back when the run ends.
            .lockedDuringRun()
            .help(ShortcutHint.tooltip("Undo this operation", "⌘Z"))
            .accessibilityLabel("Undo this operation")
        }
        ForEach(Array(banner.followUps.enumerated()), id: \.offset) { _, followUp in
            Button { onFollowUp(followUp) } label: {
                Text(Self.title(for: followUp))
                    .scaledFont(.subheadline.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: tint))
            .help(Self.help(for: followUp))
        }
        if let accessory { accessory }
    }

    private var close: some View {
        // No bar glass: a banner is not a bar, and the Undo beside this wears none.
        CloseButton(chromeGlass: false, action: onClose)
            .help("Close notification")
            .accessibilityLabel("Close notification")
    }

    private func startCountdown() {
        // Routed through the tested rule rather than re-deriving `!reduceMotion` here — this was
        // the one remaining parallel copy of the conjunction the extraction exists to end.
        guard showsCountdown, let seconds = autoDismissSeconds else { countdown = 1; return }
        countdown = 1
        withAnimation(.linear(duration: seconds)) { countdown = 0 }
    }
}
