import AppKit

/// Follows the menus SwiftUI builds and rebuilds: calls `onChange` with the menu each time an item
/// is added or changed, or a menu starts tracking. The caller keeps the observers.
enum MenuRebuildWatch {
    static func observe(_ onChange: @escaping @MainActor (NSMenu?) -> Void) -> [NSObjectProtocol] {
        let names: [Notification.Name] = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                                          NSMenu.didBeginTrackingNotification]
        return names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                // AppKit changes menus on the main thread; anything else is left alone rather than
                // trapped in `assumeIsolated`.
                guard Thread.isMainThread else { return }
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated { onChange(menu) }
            }
        }
    }
}
