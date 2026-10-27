import AppKit

/// **What VoiceOver hears as results arrive** (Run Room TE226). Each message is spoken once, where
/// it shows (R19) — and two arriving within a moment, a Compress ending as a Save as PDF does, are
/// spoken as one announcement rather than two that cut each other off: "2 new in Activity: Saved 4
/// compressed copies; Saved 6 files as PDF." A problem is spoken at high priority, interrupting; a
/// success at medium. Progress is never spoken: it is read on demand, from the capsule's label.
@MainActor
enum ActivityAnnouncer {
    /// How long a message waits for a second one to join it.
    static let window: Duration = .milliseconds(600)

    private static var pending: [(text: String, isProblem: Bool)] = []
    private static var flush: Task<Void, Never>?
    /// Where it is posted — VoiceOver in the app, a recorder in a test.
    static var post: (String, NSAccessibilityPriorityLevel) -> Void = { text, priority in
        guard let app = NSApp else { return }
        NSAccessibility.post(element: (app.mainWindow as NSResponder?) ?? app,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    static func say(_ text: String, isProblem: Bool) {
        pending.append((text, isProblem))
        guard flush == nil else { return }
        flush = Task { @MainActor in
            try? await Task.sleep(for: window)
            speak()
        }
    }

    /// Says what has gathered, now.
    static func speak() {
        let gathered = pending
        pending = []
        flush = nil
        guard let spoken = batched(gathered.map(\.text)) else { return }
        post(spoken, gathered.contains { $0.isProblem } ? .high : .medium)
    }

    /// One message as itself; several as one sentence that counts them.
    nonisolated static func batched(_ texts: [String]) -> String? {
        switch texts.count {
        case 0: return nil
        case 1: return texts[0]
        default:
            let trimmed = texts.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            return "\(texts.count) new in Activity: " + trimmed.joined(separator: "; ") + "."
        }
    }
}
