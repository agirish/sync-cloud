import SwiftUI
import AppKit
import Design
import Sync

// MARK: - The menu item

/// View ▸ Vault, ⌘U: the toolbar button's menu half. A menu item for ⌘K's reason: a focus-scoped
/// key handler never fires with focus in a file table, which is where it usually is.
struct ToggleVaultCommand: View {
    @FocusedValue(\.vault) private var vault

    var body: some View {
        Toggle("Vault", isOn: Binding(
            get: { vault?.wrappedValue ?? false },
            set: { vault?.wrappedValue = $0 }))
            .keyboardShortcut(AppChord.vault.key, modifiers: AppChord.vault.modifiers)
            .disabled(vault == nil)
    }
}

private struct VaultKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// The Vault panel. `nil` while a destination pick is up, as Settings and Help are refused
    /// then: the picker draws in front, so a panel opened under it would appear the instant the
    /// pick was answered.
    var vault: Binding<Bool>? {
        get { self[VaultKey.self] }
        set { self[VaultKey.self] = newValue }
    }
}

// MARK: - The window's half

/// Publishes ⌘U's binding and locks the Vault when the Mac does. One modifier, so the window's
/// long modifier chain stays within what the type checker can solve.
struct VaultHost: ViewModifier {
    @Binding var isShown: Bool
    /// A destination pick is up.
    let suspended: Bool
    let model: VaultModel
    /// The panel was let through: the window puts Settings and Help away.
    let onOpened: () -> Void

    func body(content: Content) -> some View {
        let workspace = NSWorkspace.shared.notificationCenter
        content
            .focusedSceneValue(\.vault, suspended ? nil : $isShown)
            // The latch, for every way in (the menu, the toolbar, ⌘K): refused while a destination
            // pick is up, since the picker draws in front and the panel would appear the instant
            // the pick was answered.
            .onChange(of: isShown) { _, open in
                guard open else { return }
                if suspended { isShown = false } else { onOpened() }
            }
            // Asleep, screen off, or switched to another user: whoever is at the Mac next proves
            // it again, whatever the "Lock again" setting says.
            .onReceive(workspace.publisher(for: NSWorkspace.willSleepNotification)) { _ in lockForTheMac() }
            .onReceive(workspace.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in lockForTheMac() }
            .onReceive(workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in lockForTheMac() }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))) { _ in
                lockForTheMac()
            }
    }

    private func lockForTheMac() {
        model.systemLocked()
        isShown = false
    }
}

// MARK: - The live model

extension VaultModel {
    /// The app's Vault: the sealed file in Application Support, macOS's own proof, and a
    /// pasteboard copy that cleans up after itself.
    static func live() -> VaultModel {
        VaultModel(store: VaultStore.defaultURL().map { VaultStore(fileURL: $0) },
                   authenticator: VaultDeviceOwnerProof(),
                   copyToPasteboard: { VaultPasteboard.copyConcealed($0) })
    }
}

/// Copying a number out of the Vault.
enum VaultPasteboard {
    /// How long a copied number stays on the pasteboard.
    static let clearAfter: Duration = .seconds(60)

    /// Copies `value`, marked concealed, and clears it a minute later unless something else was
    /// copied meanwhile. The same recipe as the API key's Copy in Settings (`CloudKeyRow`), for
    /// its reasons: clipboard-history apps snapshot the pasteboard the instant it changes and the
    /// well-behaved ones skip concealed items, and Universal Clipboard relays the general
    /// pasteboard to nearby devices.
    @MainActor
    static func copyConcealed(_ value: String) {
        let pasteboard = NSPasteboard.general
        // This Mac only: Universal Clipboard would hand the number to every nearby device signed
        // in to the same account.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        // The markers before the string: a manager watching `changeCount` reads the types as soon
        // as it sees a change. Concealed and transient are the two that clipboard-history apps
        // honour (nspasteboard.org).
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.setString(value, forType: .string)
        let stamp = pasteboard.changeCount
        pendingClear = stamp
        watchForQuit()
        Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            clear(ifStill: stamp)
        }
    }

    /// The copy that has yet to be cleared, by the pasteboard's change count.
    @MainActor private static var pendingClear: Int?
    @MainActor private static var quitWatch: NSObjectProtocol?

    @MainActor private static func clear(ifStill stamp: Int) {
        guard pendingClear == stamp else { return }
        pendingClear = nil
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == stamp else { return }
        pasteboard.clearContents()
    }

    /// Quitting inside the minute would leave the number on the clipboard for good: it is cleared
    /// on the way out, unless something else was copied since.
    @MainActor private static func watchForQuit() {
        guard quitWatch == nil else { return }
        quitWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let stamp = pendingClear { clear(ifStill: stamp) }
            }
        }
    }
}
