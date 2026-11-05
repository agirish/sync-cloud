import AppKit
import SwiftUI
import FileExplorer
import Sync
import Design

/// The result message: what the operation you just ran did. An undoable outcome
/// (`banner.isUndoable`, still on top of the undo stack) gets a one-click Undo, the visible face of
/// ⌘Z; a finished file gets its follow-ups (`banner.followUps`: Open in Edit, Reveal in Browse,
/// Download); auto-dismissing severities get a thin countdown bar.
///
/// It docks in the pane, in one stack with the contextual action bar at the edge
/// `PaneBarPlacement` picks, so it covers neither the bar, the header nor the row acted on.
///
/// A struct so it can hold the countdown `@State`. The timing lives in `BannerDismissScheduler`;
/// the bar reads the same `Delays.standard` window and resets to full on hover, as the scheduler
/// restarts its timer.
struct OperationBannerView: View {
    let banner: OperationBanner
    let glassLevel: GlassLevel
    /// Whether the undo stack has something to undo. With `banner.isUndoable` it decides the
    /// button, so a message whose operation was already undone elsewhere shows no dead Undo.
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

    /// The auto-dismiss window for this severity in seconds, or nil when the message is sticky
    /// (errors). Read from the scheduler's delays so the bar can't drift from the real timer.
    var autoDismissSeconds: Double? {
        BannerDismissScheduler.Delays.standard
            .delayNanoseconds(for: banner.severity)
            .map { Double($0) / 1_000_000_000 }
    }

    /// Whether to offer the one-click Undo. `isUndoable` says the outcome is a single undo step,
    /// `canUndo` that the stack still has it; dropping either shows a dead button or hides a live
    /// one. `body` decides from this property alone, so the truth table is testable on a
    /// constructed view.
    var showsUndo: Bool { banner.isUndoable && canUndo }

    /// The countdown-bar rule, static so the Reduce Motion arm is testable: the environment value
    /// can't be injected into a constructed view outside a render.
    static func showsCountdown(autoDismissSeconds: Double?, reduceMotion: Bool) -> Bool {
        autoDismissSeconds != nil && !reduceMotion
    }

    private var showsCountdown: Bool {
        Self.showsCountdown(autoDismissSeconds: autoDismissSeconds, reduceMotion: reduceMotion)
    }

    private var tint: Color { OperationBannerStyle.tint(for: banner.severity) }

    /// A follow-up's button title, the words the PDF tools' own banner uses for the same actions.
    static func title(for followUp: OperationBanner.FollowUp) -> String { followUp.title }

    /// Its tooltip, naming the file — or how many — it goes to. Shared with Activity's Recent.
    static func help(for followUp: OperationBanner.FollowUp) -> String { followUp.help }

    /// What VoiceOver hears when the message appears: the message and, when Undo shows, that ⌘Z
    /// takes it back.
    static func announcement(for banner: OperationBanner, offersUndo: Bool) -> String {
        guard offersUndo else { return banner.message }
        let ends = banner.message.last.map { ".!?".contains($0) } ?? false
        return banner.message + (ends ? " " : ". ") + "Undo available, Command Z"
    }

    /// Posts the announcement: a problem at high priority, spoken over whatever VoiceOver was
    /// reading; a success at medium, so it waits its turn. Two within a moment are spoken as one
    /// (``ActivityAnnouncer``).
    static func announce(_ banner: OperationBanner, offersUndo: Bool) {
        ActivityAnnouncer.say(announcement(for: banner, offersUndo: offersUndo),
                              isProblem: banner.severity != .success)
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
                // Mirror the scheduler: hovering earns a fresh full window, so show the bar full
                // (paused) rather than freezing it mid-animation.
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
            // Greyed while a long run is going, as ⌘Z is. A message up when a run starts keeps its
            // button, greyed, and has it back when the run ends.
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
        // Goes through the tested rule rather than re-deriving `!reduceMotion` here.
        guard showsCountdown, let seconds = autoDismissSeconds else { countdown = 1; return }
        countdown = 1
        withAnimation(.linear(duration: seconds)) { countdown = 0 }
    }
}
