import Foundation
import Sync

/// Owns the single auto-dismiss timer for the operation banner.
/// Every banner change cancels the previous timer, so a replacement banner — even one with the
/// exact same content — always gets the full display window, and a banner cleared elsewhere cannot
/// be dismissed early by a stale timer that merely compares values.
///
/// Dismissal rules by severity: success and warning auto-dismiss after their configured delay
/// (warnings get a longer window); errors are sticky and stay until manually closed.
/// Hovering the banner pauses the timer; on hover exit the FULL delay restarts (not the
/// remainder) — a deliberate simplification: the user was just reading the banner, so it earns
/// a fresh window.
@MainActor
final class BannerDismissScheduler {
    /// Auto-dismiss delays per severity. Injectable so tests can run on short windows.
    struct Delays {
        var successNanoseconds: UInt64 = 5_000_000_000
        var warningNanoseconds: UInt64 = 10_000_000_000

        static let standard = Delays()

        /// `nil` means the banner never auto-dismisses (sticky).
        func delayNanoseconds(for severity: OperationBanner.Severity) -> UInt64? {
            switch severity {
            case .success: return successNanoseconds
            case .warning: return warningNanoseconds
            case .error: return nil
            }
        }
    }

    private let delays: Delays
    private var dismissTask: Task<Void, Never>?
    /// The full delay window for the currently shown banner; `nil` when there is no banner or it is sticky.
    private var currentDelay: UInt64?
    private var dismiss: (@MainActor () -> Void)?
    private var isHovering = false

    init(delays: Delays = .standard) {
        self.delays = delays
    }

    /// Call from the view's `onChange` whenever the banner changes.
    /// - Parameters:
    ///   - newValue: The new banner (`nil` when the banner was cleared).
    ///   - dismiss: Runs on the main actor after the severity's delay, unless superseded,
    ///     cancelled, or the banner is sticky.
    func bannerChanged(to newValue: OperationBanner?, dismiss: @escaping @MainActor () -> Void) {
        cancelTimer()
        currentDelay = nil
        self.dismiss = nil
        guard let banner = newValue,
              let delay = delays.delayNanoseconds(for: banner.severity) else { return }
        currentDelay = delay
        self.dismiss = dismiss
        // A banner replaced while the pointer is over it stays paused until hover exit.
        if !isHovering { startTimer(delay) }
    }

    /// Call from the banner view's `onHover`. Entering pauses the auto-dismiss timer;
    /// exiting restarts it with the full delay window.
    func hoverChanged(isHovering: Bool) {
        guard isHovering != self.isHovering else { return }
        self.isHovering = isHovering
        if isHovering {
            cancelTimer()
        } else if let delay = currentDelay {
            startTimer(delay)
        }
    }

    private func startTimer(_ delayNanoseconds: UInt64) {
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismiss?()
        }
    }

    private func cancelTimer() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}
