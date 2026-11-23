import AppKit
import Design
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
    @AppStorage(VaultActivitySettings.keepsKey) private var keepsActivity: Bool = true
    /// The activity list, read after a proof and shown in a sheet; nil while it is not up.
    @State private var activityShown: [VaultActivityEvent]?
    @AppStorage(VaultBackup.weeklyKey) private var backsUpWeekly: Bool = true
    /// The backup section's state, read when the page appears and after each act.
    @State private var hasPassphrase = false
    @State private var backupFolder = ""
    @State private var lastBackup: Date?
    /// What the last backup or restore came to, in words.
    @State private var backupMessage: String?
    @State private var backupFailed = false
    @State private var isBackingUp = false
    /// A backup chosen to restore is being opened (its key derived): another choice waits.
    @State private var openingBackup = false
    @State private var settingPassphrase = false
    /// A backup file chosen to restore that the kept passphrase did not open: asked for here.
    @State private var askingPassphraseFor: BackupFile?
    /// A backup opened and waiting for the choice of how to put it back.
    @State private var restoreOffer: RestoreOffer?
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
                "Backup",
                caption: "A backup holds every saved ID, sealed under a passphrase you choose, so it opens on another Mac and for nobody without the passphrase. Keep the passphrase somewhere safe: without it a backup cannot be opened. Restoring never deletes: Replace sets the Vault that was here aside."
            ) {
                SettingsRow("Backup passphrase") {
                    HStack(spacing: 8) {
                        Text(hasPassphrase ? "Set" : "Not set").foregroundStyle(.secondary)
                        Button(hasPassphrase ? "Change…" : "Set…") { settingPassphrase = true }
                            .controlSize(.small)
                    }
                    .help("Kept in your keychain so a backup can be made without asking for it. Backups already made open with the passphrase they were made with.")
                }
                SettingsRow("Backup folder") {
                    HStack(spacing: 8) {
                        Text((backupFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseBackupFolder() }
                            .controlSize(.small)
                    }
                    .help("Where backups are written. A folder that syncs is fine: the file is sealed.")
                }
                Toggle("Back up every week", isOn: $backsUpWeekly.loggingSettingsChange("vault.backupWeekly"))
                    .help("Makes a backup when the Vault is opened and the last one is a week old. It needs a passphrase set.")
                    .disabled(!hasPassphrase)
                SettingsRow("Last backup") {
                    HStack(spacing: 8) {
                        Text(lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                            .foregroundStyle(.secondary)
                        Button("Back Up Now") { backUpNow() }
                            .controlSize(.small)
                            .disabled(!hasPassphrase || isBackingUp)
                    }
                    .help("Asks for Touch ID or your password, then writes a backup of every saved ID.")
                }
                SettingsRow("Restore from a backup") {
                    Button("Choose…") { chooseBackupToRestore() }
                        .controlSize(.small)
                        .disabled(isBackingUp)
                        .help("Opens a backup file. You choose whether to add what this Vault is missing or to replace it.")
                }
                if let backupMessage {
                    Text(backupMessage)
                        .font(.callout)
                        .foregroundStyle(backupFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsSection(
                "Activity",
                caption: "What was unlocked, shown, copied and changed in the Vault, and each proof that was refused. It names an ID, never its number, and is sealed with the Vault: not the app’s log, and never sent to Claude."
            ) {
                Toggle("Keep a list of what is done in the Vault", isOn: $keepsActivity.loggingSettingsChange("vault.keepsActivity"))
                    .help("Off, nothing more is listed. What was listed stays until you clear it.")
                SettingsRow("Vault activity") {
                    Button("Show…") { showActivity() }
                        .controlSize(.small)
                        .disabled(isAsking)
                        .help("Shows the list after Touch ID or your password.")
                }
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
                caption: "IDs you marked Not an ID, or removed after adding them from a document. Discover More doesn’t offer them again until you forget them; then the next read opens every file again."
            ) {
                SettingsRow("IDs set aside") {
                    HStack(spacing: 8) {
                        Text(setAsideCount == 1 ? "1 ID" : "\(setAsideCount) IDs")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        // No question first: forgetting only lets the next read offer them again,
                        // and Not an ID sets each one aside once more.
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
            refreshBackupState()
        }
        .sheet(isPresented: Binding(get: { activityShown != nil }, set: { if !$0 { activityShown = nil } })) {
            VaultActivitySheet(events: activityShown ?? []) {
                activityStore?.clear()
                SettingsWindowLog.log("vault.activity", "cleared")
                activityShown = []
            }
            .presentedNativeControlAccent()
        }
        .sheet(isPresented: $settingPassphrase) {
            VaultPassphraseSheet(title: hasPassphrase ? "Change the Backup Passphrase" : "Set a Backup Passphrase",
                                 note: "At least \(VaultBackupFile.leastPassphraseLength) characters. It is the only way to open a backup on another Mac, so keep it somewhere safe.",
                                 confirms: true, action: "Save") { passphrase in
                guard let backup else { return "The Vault’s folder couldn’t be found." }
                do {
                    try backup.setPassphrase(passphrase)
                    SettingsWindowLog.log("vault.backupPassphrase", "set")
                    refreshBackupState()
                    return nil
                } catch {
                    return "The Keychain wouldn’t keep the passphrase."
                }
            }
            .presentedNativeControlAccent()
        }
        .sheet(item: $askingPassphraseFor) { file in
            let url = file.url
            VaultPassphraseSheet(title: "Passphrase for This Backup",
                                 note: "“\(url.lastPathComponent)” was sealed with another passphrase than the one kept here.",
                                 confirms: false, action: "Open") { passphrase in
                guard let backup else { return "The Vault’s folder couldn’t be found." }
                switch await backup.read(url, passphrase: passphrase) {
                case .success(let contents):
                    // Cancelled while the key was derived: the sheet is gone, and so is the offer.
                    guard !Task.isCancelled else { return nil }
                    offerRestore(contents)
                    return nil
                case .failure(let error):
                    return Self.message(for: error)
                }
            }
            .presentedNativeControlAccent()
        }
        .confirmationDialog(restoreOffer?.title ?? "", isPresented: Binding(get: { restoreOffer != nil }, set: { if !$0 { restoreOffer = nil } }),
                            presenting: restoreOffer) { offer in
            if let missing = offer.missing, missing > 0 {
                Button(missing == 1 ? "Add the 1 ID Missing Here" : "Add the \(missing) IDs Missing Here") { restore(offer.contents, .addMissing) }
            }
            Button("Replace the Vault with This Backup", role: .destructive) { restore(offer.contents, .replace) }
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text(offer.message)
        }
    }

    // MARK: Activity

    private var activityStore: VaultActivityStore? {
        VaultStore.defaultURL().map { VaultActivityStore.beside(VaultStore(fileURL: $0)) }
    }

    /// The list says which IDs were used and when: it is shown to the Mac's owner only.
    private func showActivity() {
        isAsking = true
        Task { @MainActor in
            let proof = await VaultDeviceOwnerProof().prove(reason: "show the Vault’s activity")
            isAsking = false
            guard case .allowed = proof else { return }
            activityShown = activityStore?.load() ?? []
        }
    }

    // MARK: Backup

    /// A backup opened and read, and what restoring it would do.
    struct RestoreOffer {
        let contents: VaultBackupContents
        /// How many of its IDs this Vault lacks; nil when this Vault cannot be read.
        let missing: Int?

        var title: String {
            let count = contents.entries.count
            return "Restore \(count == 1 ? "1 ID" : "\(count) IDs") backed up \(contents.madeAt.formatted(date: .abbreviated, time: .omitted))?"
        }

        var message: String {
            switch missing {
            case nil: return "The Vault on this Mac can’t be opened, so the backup can only replace it. It is set aside first, never deleted."
            case 0?: return "This Vault already holds every ID in the backup. Replacing sets the Vault that is here aside first; it is never deleted."
            case let missing?: return "This Vault is missing \(missing) of them. Adding changes nothing it already holds. Replacing sets the Vault that is here aside first; it is never deleted."
            }
        }
    }

    private var backup: VaultBackup? { VaultStore.defaultURL().map { VaultBackup(store: VaultStore(fileURL: $0)) } }

    private func refreshBackupState() {
        guard let backup else { return }
        hasPassphrase = backup.hasPassphrase
        backupFolder = backup.folder.path
        lastBackup = backup.lastBackup
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: VaultBackup.folderKey)
        SettingsWindowLog.log("vault.backupFolder", "chosen")
        refreshBackupState()
    }

    private func backUpNow() {
        guard let backup else { return }
        isBackingUp = true
        Task { @MainActor in
            let result = await backup.backUpNow()
            isBackingUp = false
            switch result {
            case .success(let url):
                backupFailed = false
                backupMessage = "Backed up to “\(url.lastPathComponent)”."
                SettingsWindowLog.log("vault.backUpNow", "backed up")
            case .failure(.notProved):
                break
            case .failure(let error):
                backupFailed = true
                backupMessage = Self.message(for: error)
            }
            refreshBackupState()
        }
    }

    private func chooseBackupToRestore() {
        guard let backup else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = backup.folder
        panel.prompt = "Open Backup"
        panel.message = "Choose a Vault backup (.\(VaultBackupFile.fileExtension))."
        guard !openingBackup, panel.runModal() == .OK, let url = panel.url else { return }
        // Opened off the main actor (VT58): the key derivation takes most of a second, and a
        // second choice meanwhile waits for this one rather than offering two restores.
        openingBackup = true
        Task { @MainActor in
            defer { openingBackup = false }
            switch await backup.read(url) {
            case .success(let contents):
                offerRestore(contents)
            case .failure(.wrongPassphrase), .failure(.noPassphrase):
                askingPassphraseFor = BackupFile(url: url)
            case .failure(let error):
                backupFailed = true
                backupMessage = Self.message(for: error)
            }
        }
    }

    private func offerRestore(_ contents: VaultBackupContents) {
        restoreOffer = RestoreOffer(contents: contents, missing: backup?.missing(from: contents))
    }

    private func restore(_ contents: VaultBackupContents, _ mode: VaultRestoreMode) {
        guard let backup else { return }
        isBackingUp = true
        Task { @MainActor in
            let result = await backup.restore(contents, mode: mode)
            isBackingUp = false
            switch result {
            case .success(let count):
                backupFailed = false
                backupMessage = "Restored. The Vault now holds \(count == 1 ? "1 ID" : "\(count) IDs")."
                SettingsWindowLog.log("vault.restore", mode == .replace ? "replaced" : "added")
            case .failure(.notProved):
                break
            case .failure(let error):
                backupFailed = true
                backupMessage = Self.message(for: error)
            }
        }
    }

    /// What Settings says for each way a backup can fail.
    static func message(for error: VaultBackupError) -> String {
        switch error {
        case .noPassphrase: return "Set a backup passphrase first."
        case .passphraseTooShort: return "The passphrase needs at least \(VaultBackupFile.leastPassphraseLength) characters."
        case .notABackup: return "That file isn’t a Vault backup this version of SyncCloud can read."
        case .wrongPassphrase: return "That passphrase doesn’t open this backup."
        case .vaultUnreadable: return "The Vault on this Mac couldn’t be read."
        case .notWritten: return "The file couldn’t be written, so nothing was changed."
        case .notProved: return "macOS couldn’t confirm it was you."
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

/// A backup file a sheet is about, by its address (VT79): what `.sheet(item:)` needs, without
/// making every `URL` in the app `Identifiable`.
struct BackupFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A passphrase asked for in a sheet: to set the backup passphrase (typed twice), or to open one
/// backup made with another.
struct VaultPassphraseSheet: View {
    let title: String
    let note: String
    /// Typed twice, as a new passphrase is.
    let confirms: Bool
    let action: String
    /// Does it; nil when it worked, else what to say. Awaited, so opening a backup's key is
    /// derived off the main actor (VT58).
    let submit: @MainActor (String) async -> String?

    @State private var passphrase = ""
    @State private var again = ""
    @State private var problem: String?
    /// A submit running: a second press waits for it rather than deriving twice, and Cancel
    /// stops it, so nothing it opens appears after the sheet is gone.
    @State private var submitting: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private var isReady: Bool {
        passphrase.count >= VaultBackupFile.leastPassphraseLength && (!confirms || passphrase == again)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
            if confirms {
                SecureField("Passphrase again", text: $again)
                if !again.isEmpty, again != passphrase {
                    Text("The two don’t match yet.").font(.caption).foregroundStyle(.orange)
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    submitting?.cancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Button(action) {
                    guard submitting == nil else { return }
                    submitting = Task { @MainActor in
                        let answer = await submit(passphrase)
                        submitting = nil
                        guard !Task.isCancelled else { return }
                        problem = answer
                        if problem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accentedProminent()
                .disabled(!isReady)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 400)
        // Gone some other way (Settings closed): what it was doing opens nothing after it.
        .onDisappear { submitting?.cancel() }
    }
}

/// The Vault's activity, newest first, shown after a proof.
struct VaultActivitySheet: View {
    let events: [VaultActivityEvent]
    let clear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vault Activity").font(.headline)
            if events.isEmpty {
                Text("Nothing has been listed yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(event.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                        Text(event.line)
                            .font(.callout)
                            .foregroundStyle(event.kind == .proofRefused ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 280)
            }
            HStack {
                Button("Clear…", role: .destructive, action: clear)
                    .disabled(events.isEmpty)
                    .help("Removes the list for good.")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accentedProminent()
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
