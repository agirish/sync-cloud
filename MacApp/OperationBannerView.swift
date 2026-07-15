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
    let glassIntensity: Double
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
    private var autoDismissSeconds: Double? {
        BannerDismissScheduler.Delays.standard
            .delayNanoseconds(for: banner.severity)
            .map { Double($0) / 1_000_000_000 }
    }

    private var showsCountdown: Bool { autoDismissSeconds != nil && !reduceMotion }

    private var tint: Color { OperationBannerStyle.tint(for: banner.severity) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: OperationBannerStyle.iconName(for: banner.severity))
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(banner.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)

                if banner.isUndoable && canUndo {
                    Button(action: onUndo) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Undo")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Undo this operation (⌘Z)")
                    .accessibilityLabel("Undo this operation")
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
        .glassCardStyle(material: .ultraThickMaterial, intensity: glassIntensity)
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
        guard let seconds = autoDismissSeconds, !reduceMotion else { countdown = 1; return }
        countdown = 1
        withAnimation(.linear(duration: seconds)) { countdown = 0 }
    }
}
