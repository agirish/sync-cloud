import AppKit
import SwiftUI

/// Tracks Shift/Command so the differences list can offer “Move” instead of “Copy” when a modifier is held.
@MainActor
final class ModifierTracker: ObservableObject {
    @Published var isMoveModifierPressed: Bool = false
    nonisolated(unsafe) private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateModifiers(event.modifierFlags)
            return event
        }
    }

    /// Boxes the opaque monitor token so the nonisolated deinit can hand it to a MainActor task.
    private struct MonitorBox: @unchecked Sendable { let value: Any }

    deinit {
        // deinit is nonisolated, and nothing guarantees @StateObject teardown runs on main, so
        // hop to the main actor: AppKit's removeMonitor is main-thread only.
        if let monitor = monitor {
            let box = MonitorBox(value: monitor)
            Task { @MainActor in NSEvent.removeMonitor(box.value) }
        }
    }

    private func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        let isPressed = Self.isMoveModifier(flags)
        if isMoveModifierPressed != isPressed {
            isMoveModifierPressed = isPressed
        }
    }

    /// The app-wide "move instead of copy" modifier: Shift or Command.
    nonisolated static func isMoveModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.shift) || flags.contains(.command)
    }

    /// One-shot read of the current keyboard state (at drop time, say), for callers that don't
    /// need the published stream.
    static var moveModifierHeld: Bool {
        isMoveModifier(NSEvent.modifierFlags)
    }
}
