import SwiftUI
import Sync

/// Settings ▸ Vault: whether the Vault asks who is at the Mac, when it asks, and when it locks
/// again. The numbers themselves are never here; the panel behind ⌘U owns them.
///
/// The first switch is the one setting in the app that proves who is asking before it changes:
/// unticking it raises macOS's own Touch ID or password prompt, and stays ticked unless that is
/// answered. Otherwise the lock would guard everything but its own off switch.
struct VaultSettingsTab: View {
    @AppStorage(VaultLockSettings.requiresAuthenticationKey) private var requiresAuthentication: Bool = true
    @AppStorage(VaultLockSettings.askKey) private var ask: VaultLockSettings.Ask = .whenOpened
    @AppStorage(VaultLockSettings.relockKey) private var relock: VaultLockSettings.Relock = .afterTwoMinutes
    /// macOS's prompt is up. The switch waits for its answer rather than queue a second prompt.
    @State private var isAsking = false

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Lock",
                caption: "Turning the lock off takes Touch ID or your password. The numbers stay sealed on this Mac either way, and are never sent to Claude."
            ) {
                Toggle("Require Touch ID or your Mac password", isOn: requirement)
                    .help("Asks who is at the Mac before the Vault shows or copies a number in full. Off, anyone at this Mac while it is unlocked can read them.")
                    .disabled(isAsking)
                SettingsRow("When to ask") {
                    Picker("When to ask", selection: $ask.loggingSettingsChange("vault.ask")) {
                        ForEach(VaultLockSettings.Ask.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Once as the Vault opens, or again for each number you show or copy.")
                }
                .disabled(!requiresAuthentication)
                SettingsRow("Lock again") {
                    Picker("Lock again", selection: $relock.loggingSettingsChange("vault.relock")) {
                        ForEach(VaultLockSettings.Relock.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("When an unlocked Vault locks itself. It always locks when the Mac sleeps or its screen locks.")
                }
                // Asking for every number leaves nothing unlocked to time out.
                .disabled(!requiresAuthentication || ask == .everyNumber)
            }
        }
    }

    /// The switch. Turning it on is immediate; turning it off waits for the owner to prove it.
    private var requirement: Binding<Bool> {
        Binding(get: { requiresAuthentication }, set: { wanted in
            guard wanted != requiresAuthentication, !isAsking else { return }
            guard !wanted else { return set(true) }
            isAsking = true
            Task { @MainActor in
                let allowed = await VaultLockSwitch.mayTurnOff(using: VaultDeviceOwnerProof())
                isAsking = false
                if allowed { set(false) }
            }
        })
    }

    private func set(_ on: Bool) {
        let old = requiresAuthentication
        requiresAuthentication = on
        SettingsWindowLog.log("vault.requiresAuthentication", from: .bool(old), to: .bool(on))
    }
}
