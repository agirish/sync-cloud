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

/// Publishes ⌘U's binding, locks the Vault when the Mac does, and keeps the model's household to
/// People's. One modifier, so the window's long modifier chain stays within what the type checker
/// can solve.
struct VaultHost: ViewModifier {
    @Binding var isShown: Bool
    /// A destination pick is up.
    let suspended: Bool
    let model: VaultModel
    /// The household, Settings ▸ Organize ▸ People's: whose a read number is, and the filter's
    /// names. Handed to the model from the window's first frame, so the panel draws from it alone.
    let people: [Person]
    /// The panel was let through: the window puts Settings and Help away.
    let onOpened: () -> Void

    func body(content: Content) -> some View {
        let workspace = NSWorkspace.shared.notificationCenter
        content
            .focusedSceneValue(\.vault, suspended ? nil : $isShown)
            // People changed in Settings, or a person was added from the Vault: whose each number
            // is follows, open or not.
            .onAppear { model.people = people }
            .onChange(of: people) { _, now in model.people = now }
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
            // The window closed. A read the Vault left running would outlive these watches, and
            // with them the lock for the Mac sleeping: it stops, keeping what it sealed so far.
            .onDisappear { model.systemLocked() }
    }

    private func lockForTheMac() {
        model.systemLocked()
        // The Mac asleep or locked: a copied number does not wait out its time on the clipboard.
        VaultPasteboard.clearPending()
        isShown = false
    }
}

// MARK: - The live model

extension VaultModel {
    /// The app's Vault: the sealed file in Application Support, macOS's own proof, its weekly
    /// backup, and a pasteboard copy that cleans up after itself.
    static func live() -> VaultModel {
        let store = VaultStore.defaultURL().map { VaultStore(fileURL: $0) }
        return VaultModel(store: store,
                          authenticator: VaultDeviceOwnerProof(),
                          activity: store.map { VaultActivityStore.beside($0) },
                          backup: store.map { VaultBackup(store: $0) },
                          copyToPasteboard: { VaultPasteboard.copyConcealed($0) })
    }
}

/// Keeps a shown ID out of screen sharing, recordings and screenshots.
///
/// The Vault is drawn inside the app's window, so it is the window that is left out of what other
/// apps can capture, and only while an ID is drawn in full: locked, or with every ID showing its
/// ending alone, the window shares as usual. The user's own screenshots come out without it too;
/// Settings ▸ Vault turns this off.
@MainActor
enum VaultWindowPrivacy {
    /// What the window should be while `exposed` says an ID is drawn in full.
    static func sharing(exposed: Bool, defaults: UserDefaults = .standard) -> NSWindow.SharingType {
        exposed && VaultSharingSettings.hidesFromCapture(in: defaults) ? .none : .readOnly
    }

    static func apply(exposed: Bool, to window: NSWindow?, defaults: UserDefaults = .standard) {
        guard let window else { return }
        let wanted = sharing(exposed: exposed, defaults: defaults)
        if window.sharingType != wanted { window.sharingType = wanted }
    }
}

/// Copying a number out of the Vault.
enum VaultPasteboard {
    /// How long a copied number stays on the pasteboard: a minute unless Settings ▸ Vault says
    /// otherwise. Read at each copy, so a change applies to the next one.
    static var clearAfter: Duration { clearAfter(in: .standard) }
    static func clearAfter(in defaults: UserDefaults) -> Duration { .seconds(VaultSharingSettings.clipboardSeconds(in: defaults)) }

    /// Copies `value`, marked concealed, and clears it a minute later unless something else was
    /// copied meanwhile. The same recipe as the API key's Copy in Settings (`CloudKeyRow`), for
    /// its reasons: clipboard-history apps snapshot the pasteboard the instant it changes and the
    /// well-behaved ones skip concealed items, and Universal Clipboard relays the general
    /// pasteboard to nearby devices.
    ///
    /// `pasteboard` and `after` are the general pasteboard and the setting's time; a test hands in
    /// a pasteboard of its own and a short time, so it never touches the user's clipboard.
    @MainActor
    static func copyConcealed(_ value: String, on pasteboard: NSPasteboard = .general, after delay: Duration? = nil) {
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
        pendingClear = (pasteboard, stamp)
        watchForQuit()
        let delay = delay ?? clearAfter
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            clear(ifStill: stamp, on: pasteboard)
        }
    }

    /// Copies `value` as any app would: neither concealed nor cleared, and relayed by Universal
    /// Clipboard. For what the panel draws in clear (a name, a date, a phone, a word), never an ID's
    /// number.
    @MainActor
    static func copyPlain(_ value: String, on pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    /// The copy that has yet to be cleared: its pasteboard, and that pasteboard's change count.
    @MainActor private static var pendingClear: (pasteboard: NSPasteboard, stamp: Int)?
    @MainActor private static var quitWatch: NSObjectProtocol?

    @MainActor private static func clear(ifStill stamp: Int, on pasteboard: NSPasteboard) {
        guard let pending = pendingClear, pending.stamp == stamp, pending.pasteboard === pasteboard else { return }
        pendingClear = nil
        guard pasteboard.changeCount == stamp else { return }
        pasteboard.clearContents()
    }

    /// What quitting, a lock and closing the Vault do: clears the copy still waiting, unless
    /// something else was copied since.
    @MainActor static func clearPending() {
        if let pending = pendingClear { clear(ifStill: pending.stamp, on: pending.pasteboard) }
    }

    /// Quitting inside the minute would leave the number on the clipboard for good: it is cleared
    /// on the way out, unless something else was copied since.
    @MainActor private static func watchForQuit() {
        guard quitWatch == nil else { return }
        quitWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { clearPending() }
        }
    }
}
