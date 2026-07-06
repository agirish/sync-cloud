import Foundation

/// Owns the single auto-dismiss timer for the operation banner.
/// Every banner change cancels the previous timer, so a replacement banner — even one with the
/// exact same text — always gets the full display window, and a banner cleared elsewhere cannot
/// be dismissed early by a stale timer that merely compares string values.
@MainActor
final class BannerDismissScheduler {
    private var dismissTask: Task<Void, Never>?

    /// Call from the view's `onChange` whenever the banner message changes.
    /// - Parameters:
    ///   - newValue: The new banner message (`nil` when the banner was cleared).
    ///   - delayNanoseconds: How long the banner stays visible.
    ///   - dismiss: Runs on the main actor after the delay, unless superseded or cancelled.
    func bannerChanged(to newValue: String?, delayNanoseconds: UInt64, dismiss: @escaping @MainActor () -> Void) {
        dismissTask?.cancel()
        dismissTask = nil
        guard newValue != nil else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
