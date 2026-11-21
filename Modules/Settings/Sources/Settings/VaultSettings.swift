import AppKit
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
    @AppStorage(VaultLockSettings.relockKey) private var relock: VaultLockSettings.Relock = .afterOneMinute
    @AppStorage(VaultSharingSettings.clipboardSecondsKey) private var clipboardSeconds: Int = VaultSharingSettings.defaultClipboardSeconds
    @AppStorage(VaultSharingSettings.hidesFromCaptureKey) private var hidesFromCapture: Bool = true
    /// Whether Refresh runs by itself as the Vault opens (``VaultRefresh``).
    @AppStorage(VaultRefresh.automaticKey) private var refreshesByItself: Bool = true
    /// macOS's prompt is up. The switch waits for its answer rather than queue a second prompt.
    @State private var isAsking = false
    /// Settings ▸ Vault ▸ Folders to read, read again when the page appears.
    @State private var readFolders: [String] = []
    /// How many numbers Read Documents keeps out, counted when the page appears.
    @State private var setAsideCount = 0

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Lock",
                caption: "Turning the lock off takes Touch ID or your password. The IDs stay sealed on this Mac either way, and are never sent to Claude."
            ) {
                Toggle("Require Touch ID or your Mac password", isOn: requirement)
                    .help("Asks who is at the Mac before the Vault shows or copies an ID in full. Off, anyone at this Mac while it is unlocked can read them.")
                    .disabled(isAsking)
                SettingsRow("When to ask") {
                    Picker("When to ask", selection: $ask.loggingSettingsChange("vault.ask")) {
                        ForEach(VaultLockSettings.Ask.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Once as the Vault opens, or again for each ID you show or copy.")
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
            SettingsSection(
                "Copying and Sharing",
                caption: "A copied ID is marked so clipboard-history apps skip it, stays on this Mac, and is cleared. While an ID is shown in full, SyncCloud’s window is left out of screen sharing and recordings; your own screenshots of it come out without the window too."
            ) {
                SettingsRow("Clear the clipboard after") {
                    Picker("Clear the clipboard after", selection: $clipboardSeconds.loggingSettingsChange("vault.clipboardSeconds")) {
                        ForEach(VaultSharingSettings.clipboardChoices, id: \.self) { seconds in
                            Text(VaultSharingSettings.label(seconds: seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("How long an ID copied from the Vault stays on the clipboard.")
                }
                Toggle("Hide from screen sharing while an ID is shown", isOn: $hidesFromCapture.loggingSettingsChange("vault.hidesFromScreenSharing"))
                    .help("Keeps SyncCloud’s window out of screen sharing, recordings and screenshots while the Vault shows an ID in full. Off, a shared screen shows it.")
            }
            SettingsSection(
                "Folders to Read",
                caption: "Discover More in the Vault looks in these folders for passports, visas and OCI cards, I-94 records and USCIS receipt numbers, and for driver’s licenses, Social Security cards, ITINs, PAN, Aadhaar and voter IDs; under Health, Home, Vehicles and School, for account numbers, one paper per account per year. It looks only when you ask, on this Mac, opens only new and changed files after the first time, and adds nothing until you confirm it. Refresh reads again only the documents IDs came from. You can also change the folders from the arrow beside the Vault’s Discover More button."
            ) {
                SettingsRow("Folders") {
                    // One column, right-aligned: each folder's Remove lines up under the last, and
                    // Add… under them.
                    VStack(alignment: .trailing, spacing: 6) {
                        if readFolders.isEmpty {
                            Text("None yet").foregroundStyle(.secondary)
                        }
                        ForEach(readFolders, id: \.self) { folder in
                            HStack(spacing: 8) {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text((folder as NSString).abbreviatingWithTildeInPath)
                                        .lineLimit(1).truncationMode(.middle)
                                    if !FileManager.default.fileExists(atPath: folder) {
                                        Text("Not found. Renamed or moved?")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Button("Remove") {
                                    VaultReadFolders.remove(folder)
                                    SettingsWindowLog.log("vault.readFolders", "removed")
                                    readFolders = VaultReadFolders.folders()
                                }
                                .controlSize(.small)
                                .frame(minWidth: 70, alignment: .trailing)
                                .accessibilityLabel("Stop reading \((folder as NSString).lastPathComponent)")
                            }
                        }
                        Button("Add…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = true
                            panel.prompt = "Read for IDs"
                            if panel.runModal() == .OK {
                                for url in panel.urls { VaultReadFolders.add(url.path) }
                                SettingsWindowLog.log("vault.readFolders", "added")
                                readFolders = VaultReadFolders.folders()
                            }
                        }
                        .controlSize(.small)
                        .frame(minWidth: 70, alignment: .trailing)
                    }
                    .help("Folders and everything in them: the first three pages of each scan or PDF, skipping files over 60 MB.")
                }
                Toggle("Refresh by itself when the Vault opens", isOn: $refreshesByItself.loggingSettingsChange("vault.refreshesByItself"))
                    .help("Reads again a document an ID came from when it has changed, and all of them after an update. It opens no other file. Off, Refresh waits in the arrow beside Discover More.")
            }
            SettingsSection(
                "Set Aside",
                caption: "IDs you marked Not a Real ID, or removed after adding them from a document. Discover More doesn’t offer them again until you forget them; then the next read opens every file again."
            ) {
                SettingsRow("IDs set aside") {
                    HStack(spacing: 8) {
                        Text(setAsideCount == 1 ? "1 ID" : "\(setAsideCount) IDs")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        // No question first: forgetting only lets the next read offer them again,
                        // and Not a Real ID sets each one aside once more.
                        Button("Forget") {
                            VaultSetAside.forget()
                            SettingsWindowLog.log("vault.setAside", "forgotten")
                            setAsideCount = 0
                        }
                        .controlSize(.small)
                        .frame(minWidth: 70, alignment: .trailing)
                        .disabled(setAsideCount == 0)
                    }
                    .help("Forget, and the next read opens every file and offers these IDs again.")
                }
            }
        }
        .onAppear {
            readFolders = VaultReadFolders.folders()
            setAsideCount = VaultSetAside.fingerprints().count
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
        // Sealed first, so the Vault never reads an unsealed "off" and turns the lock back on.
        if on {
            VaultLockSwitch.unseal(in: .standard, store: VaultStore.defaultURL().map { VaultStore(fileURL: $0) })
        } else {
            VaultLockSwitch.sealOff(in: .standard, store: VaultStore.defaultURL().map { VaultStore(fileURL: $0) })
        }
        requiresAuthentication = on
        SettingsWindowLog.log("vault.requiresAuthentication", from: .bool(old), to: .bool(on))
    }
}
