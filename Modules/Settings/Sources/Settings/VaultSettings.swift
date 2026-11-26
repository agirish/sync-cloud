import AppKit
import Design
import SwiftUI
import Sync

/// Settings ▸ Vault: when the Vault asks who is at the Mac, and when it locks again. The lock is
/// always on, and without Touch ID set up the Vault is not used (owner, 2026-11-24). The numbers
/// themselves are never here; the panel behind ⌘U owns them.
struct VaultSettingsTab: View {
    /// The app's Vault: Set Aside counts and forgets through it (``VaultModel/setAsideCount``,
    /// ``VaultModel/forgetSetAside()``), wherever it keeps the numbers.
    var vault: VaultModel?
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
    /// When Touch ID was given to open the backup being restored: Restore asks again only after
    /// ``VaultBackup/proofLasts`` (VT114).
    @State private var restoreProvedAt: Date?
    /// macOS's prompt is up. Show… waits for its answer rather than queue a second prompt.
    @State private var isAsking = false
    /// Why the Vault is not used on this Mac: Touch ID is not set up. Asked as the page appears
    /// and whenever the app comes back to the front.
    @State private var touchIDMissing: String?

    private func checkTouchID() {
        if case .notSetUp(let why) = VaultDeviceOwnerProof().touchID { touchIDMissing = why } else { touchIDMissing = nil }
    }
    /// Settings ▸ Vault ▸ Folders to read, read again when the page appears.
    @State private var readFolders: [String] = []
    /// How many numbers Read Documents keeps out, counted when the page appears; nil while the
    /// Vault that holds them is locked.
    @State private var setAsideCount: Int? = 0

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Lock",
                caption: "The Vault asks for Touch ID before it shows or copies an ID in full. The IDs stay sealed on this Mac, and are never sent to Claude."
            ) {
                if let touchIDMissing {
                    // Not used at all without Touch ID: what opens the Vault here waits for it.
                    Label(touchIDMissing, systemImage: "touchid")
                        .foregroundStyle(SemanticColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                .disabled(ask == .everyNumber)
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
                        Button(hasPassphrase ? "Change…" : "Set…") {
                            Task { @MainActor in
                                if await proved(hasPassphrase ? "change the Vault’s backup passphrase" : "set the Vault’s backup passphrase") {
                                    settingPassphrase = true
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(isAsking || touchIDMissing != nil)
                    }
                    .help("Asks for Touch ID. Kept in your keychain so a backup can be made without asking for it. Backups already made open with the passphrase they were made with.")
                }
                SettingsRow("Backup folder") {
                    HStack(spacing: 8) {
                        Text((backupFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            Task { @MainActor in
                                if await proved("choose where the Vault’s backups go") { chooseBackupFolder() }
                            }
                        }
                        .controlSize(.small)
                        .disabled(isAsking || touchIDMissing != nil)
                    }
                    .help("Asks for Touch ID. Where backups are written. A folder that syncs is fine: the file is sealed.")
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
                            .disabled(!hasPassphrase || isBackingUp || touchIDMissing != nil)
                    }
                    .help(touchIDMissing == nil ? "Asks for Touch ID, then writes a backup of every saved ID."
                          : "Set up Touch ID to back up the Vault.")
                }
                SettingsRow("Restore from a backup") {
                    Button("Choose…") { chooseBackupToRestore() }
                        .controlSize(.small)
                        .disabled(isBackingUp || touchIDMissing != nil)
                        .help("Asks for Touch ID, then opens a backup file. You choose whether to add what this Vault is missing or to replace it.")
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
                        .disabled(isAsking || touchIDMissing != nil)
                        .help("Shows the list after Touch ID.")
                }
            }
            SettingsSection(
                "Folders to Read",
                caption: "Discover More in the Vault looks in these folders for passports, visas and OCI cards, I-94 records and USCIS receipt numbers, and for driver’s licenses, Social Security cards, ITINs, PAN, Aadhaar and voter IDs; under Health, Home, Vehicles and School, for account numbers, one paper per account per year. It looks only when you ask, on this Mac, opens only new and changed files after the first time, and adds nothing until you confirm it. Refresh reads again only the document each ID is read from. You can also change the folders from the arrow beside the Vault’s Discover More button."
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
                                    VaultReadFolders.remove(folder, in: .standard)
                                    SettingsWindowLog.log("vault.readFolders", "removed")
                                    readFolders = VaultReadFolders.folders(in: .standard)
                                }
                                .controlSize(.small)
                                .frame(minWidth: 70, alignment: .trailing)
                                .accessibilityLabel("Stop reading \((folder as NSString).lastPathComponent)")
                            }
                        }
                        Button("Add…") {
                            if VaultReadFoldersPanel.add() {
                                SettingsWindowLog.log("vault.readFolders", "added")
                                readFolders = VaultReadFolders.folders(in: .standard)
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
                        Text(Self.setAsideLabel(setAsideCount))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        // No question first: forgetting only lets the next read offer them again,
                        // and Not an ID sets each one aside once more.
                        Button("Forget") {
                            if forgetSetAside() {
                                SettingsWindowLog.log("vault.setAside", "forgotten")
                            }
                            setAsideCount = countSetAside()
                        }
                        .controlSize(.small)
                        .frame(minWidth: 70, alignment: .trailing)
                        .disabled((setAsideCount ?? 0) == 0)
                    }
                    .help(setAsideCount == nil ? "Open the Vault to count them or forget them: they are sealed with it."
                          : "Forget, and the next read opens every file and offers these IDs again.")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkTouchID()
        }
        .onAppear {
            checkTouchID()
            readFolders = VaultReadFolders.folders(in: .standard)
            setAsideCount = countSetAside()
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

    // MARK: Set Aside

    /// How many numbers are set aside: the Vault's own count (its document's from 7.2), or nil
    /// while it holds them sealed. With no Vault given, UserDefaults', as before 7.2.
    private func countSetAside() -> Int? {
        guard let vault else { return VaultSetAside.fingerprints().count }
        return vault.setAsideCount
    }

    /// Forget, wherever the numbers are kept. False when nothing was forgotten (the Vault's
    /// document is not open, or could not be written).
    private func forgetSetAside() -> Bool {
        guard let vault else {
            VaultSetAside.forget()
            return true
        }
        return vault.forgetSetAside()
    }

    static func setAsideLabel(_ count: Int?) -> String {
        guard let count else { return "Open the Vault to count" }
        return count == 1 ? "1 ID" : "\(count) IDs"
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
            activityShown = activityStore?.load(now: Date()) ?? []
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

    /// Touch ID before a change to the backup or a restore (VT114, owner, 2026-11-26): someone at
    /// the unlocked Mac must not send the next backup, every ID in it, somewhere of theirs.
    private func proved(_ reason: String) async -> Bool {
        guard let backup, !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        return await backup.prove(reason)
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
            // Touch ID before the backup is opened and this Vault's IDs counted against it (VT114).
            guard await proved("open a backup of your Vault") else { return }
            restoreProvedAt = Date()
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
            let result = await backup.restore(contents, mode: mode, provedAt: restoreProvedAt)
            restoreProvedAt = nil
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
        case .newerFormat: return "A newer version of SyncCloud made this. Update SyncCloud to use it."
        }
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
    /// Clear… asks first: the list cannot be brought back.
    @State private var confirmingClear = false

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
                Button("Clear…", role: .destructive) { confirmingClear = true }
                    .disabled(events.isEmpty)
                    .help("Removes the list for good.")
                    .confirmationDialog("Clear the Vault’s activity list?", isPresented: $confirmingClear) {
                        Button("Clear List", role: .destructive, action: clear)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("What it lists can’t be brought back.")
                    }
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

/// Adding folders to read for IDs, from Settings ▸ Vault ▸ Folders to Read or the Vault's own Add
/// Folder…: one panel for both.
@MainActor
public enum VaultReadFoldersPanel {
    /// Asks for folders, with `message` over the panel, and adds those chosen to the list to read
    /// as ``VaultReadFolders/add(_:in:)`` does. False when cancelled.
    public static func add(message: String? = nil) -> Bool {
        guard let chosen = choose(message: message) else { return false }
        for path in chosen { VaultReadFolders.add(path, in: .standard) }
        return true
    }

    /// Asks for folders, with `message` over the panel, and answers their paths: nil when
    /// cancelled. The Vault adds them to its own settings (VT74).
    public static func choose(message: String? = nil) -> [String]? {
        let panel = panel(message: message)
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.map(\.path)
    }

    /// The panel, built and not run: folders only, several at once.
    static func panel(message: String?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Read for IDs"
        if let message { panel.message = message }
        return panel
    }
}
