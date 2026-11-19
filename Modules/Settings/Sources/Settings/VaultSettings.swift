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
    @AppStorage(VaultLockSettings.relockKey) private var relock: VaultLockSettings.Relock = .afterTwoMinutes
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
            SettingsSection(
                "Folders to Read",
                caption: "Read Documents in the Vault looks in these folders for passports, US visas, I-94 records and USCIS receipt numbers, and for driver’s licenses, Social Security cards, ITINs, PAN, Aadhaar and voter IDs. It reads only when you ask, on this Mac, opens only new and changed files after the first time, and adds nothing until you confirm it. You can also change the folders from the arrow beside the Vault’s Read Documents button."
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
                            panel.prompt = "Read for Numbers"
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
            }
            SettingsSection(
                "Set Aside",
                caption: "Numbers you chose Not This for, or removed after adding them from a document. Read Documents doesn’t offer them again until you forget them; then the next read opens every file again."
            ) {
                SettingsRow("Numbers set aside") {
                    HStack(spacing: 8) {
                        Text(setAsideCount == 1 ? "1 number" : "\(setAsideCount) numbers")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        // No question first: forgetting only lets the next read offer them again,
                        // and Not This sets each one aside once more.
                        Button("Forget") {
                            VaultSetAside.forget()
                            SettingsWindowLog.log("vault.setAside", "forgotten")
                            setAsideCount = 0
                        }
                        .controlSize(.small)
                        .frame(minWidth: 70, alignment: .trailing)
                        .disabled(setAsideCount == 0)
                    }
                    .help("Forget, and the next Read Documents opens every file and offers these numbers again.")
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
        requiresAuthentication = on
        SettingsWindowLog.log("vault.requiresAuthentication", from: .bool(old), to: .bool(on))
    }
}
