import SwiftUI
import Sync
import Design

/// The transient in-app completion banner. Beyond the message + close button, an undoable outcome
/// (`banner.isUndoable`, and the undo stack still has it on top) gets a one-click **Undo** — the
/// visible face of the ⌘Z that already works — and auto-dismissing severities get a thin countdown
/// bar so the disappearing window is legible.
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

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: OperationBannerStyle.iconName(for: banner.severity))
                    .scaledFont(.title3)
                    .foregroundStyle(tint)
                Text(banner.message)
                    .scaledFont(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)

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
                    .help(ShortcutHint.tooltip("Undo this operation", "⌘Z"))
                    .accessibilityLabel("Undo this operation")
                }

                CloseButton(action: onClose)
                    .accessibilityLabel("Close notification")
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
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
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

    private func startCountdown() {
        // Routed through the tested rule rather than re-deriving `!reduceMotion` here — this was
        // the one remaining parallel copy of the conjunction the extraction exists to end.
        guard showsCountdown, let seconds = autoDismissSeconds else { countdown = 1; return }
        countdown = 1
        withAnimation(.linear(duration: seconds)) { countdown = 0 }
    }
}
