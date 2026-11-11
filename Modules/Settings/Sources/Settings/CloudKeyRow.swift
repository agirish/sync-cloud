import AppKit
import Design
import Security
import SwiftUI
import Sync

/// Which shape the Anthropic key row is wearing.
///
/// A value, so the row's states and transitions can be asserted without rendering it.
enum CloudKeyRowState: Equatable {
    /// No key stored: the entry field, and nothing to reveal or remove.
    case empty
    /// A key is stored and masked. The resting state, and the one that must never read the
    /// secret — see ``AnthropicKeychain/isConfigured``.
    case stored
    /// A key is stored and currently on screen.
    case revealed
    /// Entering a replacement over a stored key, with a way back out.
    case replacing

    static func resolve(hasStoredKey: Bool, isRevealed: Bool, isReplacing: Bool) -> CloudKeyRowState {
        // Replacing wins: the user asked for the field, even with a key stored or on screen.
        if isReplacing { return .replacing }
        guard hasStoredKey else { return .empty }
        return isRevealed ? .revealed : .stored
    }

    /// Whether the row shows the entry field rather than the stored key.
    var isEntry: Bool { self == .empty || self == .replacing }
    /// Whether a secret is on screen.
    var showsSecret: Bool { self == .revealed }
    /// Whether Remove is offered. Only a stored key can be removed, and never from inside the
    /// entry field — Cancel is the way out of that.
    var offersRemove: Bool { self == .stored || self == .revealed }
    /// Whether Copy is offered: only with something on screen to copy.
    var offersCopy: Bool { self == .revealed }
}

/// The Anthropic API key control: a stored key (masked, with a reveal eye) or the entry field,
/// plus Test, Replace…, Remove and the status line. Its own view because it owns five pieces of
/// state and all of Settings' Keychain contact, which can then be exercised on their own.
struct CloudKeyRow: View {
    @State private var apiKeyField: String
    @State private var hasStoredKey: Bool
    @State private var testingKey = false
    @State private var keyTestResult: AnthropicKeyCheck.Result?
    /// The key while it is on screen, and the only place the revealed secret lives. `@State`, so
    /// leaving the tab or closing Settings destroys it; `onDisappear` clears it too.
    @State private var revealedKey: String?
    /// Whether the row is in entry mode over a stored key.
    @State private var isReplacingKey: Bool

    /// Answers "is a key stored?" when the row appears. Injectable because the default reaches the
    /// real login Keychain, and because `onAppear` would otherwise overwrite a caller's state.
    private let probeStoredKey: () -> Bool

    /// Asks before Remove deletes the key. Injectable for the same reason as `probeStoredKey`: the
    /// default is a modal alert, which a render or a test must not raise.
    private let confirmRemoveKey: @MainActor () -> Bool

    /// Starting state. The app uses the defaults and the row seeds itself from the Keychain on
    /// appear; previews and layout checks pass a state with a matching probe.
    init(
        hasStoredKey: Bool = false,
        revealedKey: String? = nil,
        isReplacingKey: Bool = false,
        probeStoredKey: @escaping () -> Bool = { AnthropicKeychain.isConfigured },
        confirmRemoveKey: @escaping @MainActor () -> Bool = CloudKeyRow.defaultRemoveConfirmation
    ) {
        _apiKeyField = State(initialValue: "")
        _hasStoredKey = State(initialValue: hasStoredKey)
        _revealedKey = State(initialValue: revealedKey)
        _isReplacingKey = State(initialValue: isReplacingKey)
        self.probeStoredKey = probeStoredKey
        self.confirmRemoveKey = confirmRemoveKey
    }

    /// Remove as one step: ask, and only then delete. **Never delete on one click**: the button
    /// sits beside Replace… and Test, and the key can't be recovered from SyncCloud. Static and
    /// confirmer-taking so tests reach the decision without mounting the row.
    /// - Returns: Whether the key was removed.
    @discardableResult
    static func removeIfConfirmed(confirm: () -> Bool, remove: () -> Void) -> Bool {
        guard confirm() else { return false }
        remove()
        return true
    }

    /// What Remove asks.
    static let removePrompt = (
        messageText: "Remove the API key?",
        informativeText: "This deletes your Anthropic API key from the Keychain. Refine can’t use "
            + "Claude until you add a key again, and this can’t be undone. The Claude Console "
            + "can issue a new key.",
        confirmTitle: "Remove Key")

    /// The standard alert: Cancel is the default, and the destructive button takes no Return key.
    @MainActor static func defaultRemoveConfirmation() -> Bool {
        NativeAlerts.confirmIrreversible(messageText: removePrompt.messageText,
                                         informativeText: removePrompt.informativeText,
                                         confirmTitle: removePrompt.confirmTitle)
    }

    private var state: CloudKeyRowState {
        .resolve(hasStoredKey: hasStoredKey, isRevealed: revealedKey != nil, isReplacing: isReplacingKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isEntry { keyEntryRow } else { storedKeyRow }

            keyStatusLine

            if state.isEntry {
                Link(destination: URL(string: "https://platform.claude.com/settings/keys")!) {
                    Text("Get a key from the Claude Console ↗").scaledFont(.subheadline)
                }
            }
        }
        .onAppear {
            // The default probe is `isConfigured`, not `hasKey`: reading the secret here would
            // raise the Keychain password prompt just for opening the tab.
            hasStoredKey = probeStoredKey()
        }
        // Belt and braces, since leaving the tab already destroys this state: a revealed secret
        // must not outlive the view that showed it.
        .onDisappear { revealedKey = nil }
    }

    // MARK: - The two shapes

    /// A stored key: masked or revealed, then the actions. Masked, the key sits on one line beside
    /// the buttons. Revealed, it takes the full width and the buttons drop beneath it: beside four
    /// buttons the box is ~330pt, too narrow for a ~108-character key at any line count.
    @ViewBuilder private var storedKeyRow: some View {
        if state.showsSecret {
            VStack(alignment: .leading, spacing: 8) {
                keyBox
                HStack(spacing: 8) { storedKeyActions }.controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                keyBox
                storedKeyActions
            }
            .controlSize(.small)
        }
    }

    /// The key itself — dots or the secret — with the reveal eye at its trailing edge.
    private var keyBox: some View {
        HStack(spacing: 6) {
            if let revealedKey {
                Text(revealedKey)
                    .scaledFont(.system(.callout, design: .monospaced))
                    // A ceiling: a ~108-character key takes two lines, and the third lets a longer
                    // one grow. Past that, middle truncation keeps the prefix and tail, which
                    // identify the key.
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    // Selectable, so the key can also be taken by hand rather than by Copy.
                    .textSelection(.enabled)
            } else {
                // A fixed run of dots, not one per character, which would publish the key's length.
                Text(String(repeating: "•", count: 16))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                if revealedKey == nil { revealKey() } else { revealedKey = nil }
            } label: {
                Image(systemName: state.showsSecret ? "eye.slash" : "eye").hoverInk()
            }
            .buttonStyle(.hoverAffordance(.glyph))
            .accessibilityLabel(state.showsSecret ? "Hide the API key" : "Reveal the API key")
            .help(state.showsSecret
                  ? "Hide the key"
                  : "Show the key. macOS will ask for permission to read it.")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .searchFieldSurface()
    }

    @ViewBuilder private var storedKeyActions: some View {
        if state.offersCopy {
            Button("Copy", action: copyRevealedKey)
                .help("Copy the key. The pasteboard is cleared again after a minute.")
        }
        testButton
        Button("Replace…") {
            isReplacingKey = true
            revealedKey = nil
            apiKeyField = ""
            keyTestResult = nil
        }
        .help("Enter a new key. The one stored now is replaced when you save.")
        if state.offersRemove {
            Button("Remove") {
                Self.removeIfConfirmed(confirm: confirmRemoveKey, remove: removeKey)
            }
            .help("Delete the key from your Keychain. Asks first.")
        }
        if state.showsSecret { Spacer(minLength: 0) }
    }

    /// First run, or an explicit Replace…: the field, Save, and a way back out.
    @ViewBuilder private var keyEntryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SecureField(isReplacingKey ? "Paste the new sk-ant-… key" : "Paste sk-ant-… key",
                            text: $apiKeyField)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSave { saveTypedKey() } }
                    .help("Your Anthropic API key. Save or Return stores it in your Keychain.")
                Button("Save", action: saveTypedKey)
                    .disabled(!canSave)
                testButton
                if isReplacingKey {
                    Button("Cancel") {
                        isReplacingKey = false
                        apiKeyField = ""
                        // The verdict was about the discarded candidate; left standing it would
                        // show above the stored key's row as if about that key. `Replace…`
                        // clears it on the way in for the same reason.
                        keyTestResult = nil
                    }
                }
            }
            .controlSize(.small)

            // Only while replacing. On first run the status line and the section caption already
            // say what this would.
            if isReplacingKey {
                Text("Saving replaces the key currently in your Keychain.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var testButton: some View {
        Button { Task { await testKey() } } label: {
            if testingKey { ProgressView().controlSize(.small) } else { Text("Test") }
        }
        // In the entry field, Test checks what was typed, so it needs something typed. While
        // replacing, an empty field would otherwise test the old stored key and prompt for it.
        .disabled(testingKey || (state.isEntry && !canSave))
        .help(testHelp)
    }

    /// What Test checks, and whether it has to read the Keychain to do it — see `testKey`.
    private var testHelp: String {
        switch state {
        case .empty, .replacing:
            return "Check the key you pasted with Anthropic. Free, and no files are sent."
        case .revealed:
            return "Check this key with Anthropic. Free, and no files are sent."
        case .stored:
            return "Check the stored key with Anthropic. Free, and no files are sent. macOS may ask for permission to read the key."
        }
    }

    private var canSave: Bool {
        !apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var keyStatusLine: some View {
        if testingKey {
            Label("Testing…", systemImage: "ellipsis.circle").scaledFont(.subheadline).foregroundStyle(.secondary)
        } else if let keyTestResult {
            switch keyTestResult {
            case .valid:
                Label("Key works — you’re set.", systemImage: "checkmark.circle.fill").scaledFont(.subheadline).foregroundStyle(.green)
            case .invalid(let message):
                Label(message, systemImage: "xmark.octagon.fill").scaledFont(.subheadline).foregroundStyle(.red)
            case .failed(let message):
                Label("Couldn’t reach Anthropic: \(message)", systemImage: "exclamationmark.triangle.fill").scaledFont(.subheadline).foregroundStyle(.orange)
            }
        } else if state.showsSecret {
            // The one state worth interrupting the usual reassurance for: a secret is on screen.
            Label("Visible until you hide it or leave Settings.", systemImage: "eye")
                .scaledFont(.subheadline).foregroundStyle(.orange)
        } else if state == .replacing {
            EmptyView()   // the entry row carries its own caption
        } else if hasStoredKey {
            Label("Key saved to Keychain.", systemImage: "checkmark.circle").scaledFont(.subheadline).foregroundStyle(.secondary)
        } else {
            Text("No key yet — cloud suggestions fall back to the on-device model until you add one.")
                .scaledFont(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func saveTypedKey() {
        let status = AnthropicKeychain.store(apiKeyField)
        // Confirming the write only needs the item to exist; reading it back would prompt for
        // permission right after the user typed the key.
        hasStoredKey = AnthropicKeychain.isConfigured
        revealedKey = nil
        let after = Self.afterSave(typed: apiKeyField, status: status, stored: hasStoredKey,
                                   wasReplacing: isReplacingKey)
        if after.failure == nil { SettingsWindowLog.log("intelligence.apiKey", isReplacingKey ? "replaced" : "saved") }
        apiKeyField = after.field
        isReplacingKey = after.isReplacing
        keyTestResult = after.failure.map { .invalid($0) }
    }

    /// What the row shows after a Save: on success, the stored key; on a refused write (locked or
    /// denied keychain, an MDM policy), the entry field **still holding what was typed**, since it
    /// is the only copy, with the refusal said under it. Replacing stays in entry mode so the
    /// typed key stays visible. The failure is `.invalid`, shown verbatim; `.failed` would blame
    /// the network. Static, so tests reach it without mounting the row.
    static func afterSave(typed: String, status: OSStatus, stored: Bool,
                          wasReplacing: Bool) -> (field: String, isReplacing: Bool, failure: String?) {
        if status == errSecSuccess, stored { return ("", false, nil) }
        return (typed, wasReplacing,
                "The Keychain refused to store the key (status \(status)). Unlock your login keychain and try again.")
    }

    /// Deletes the key and confirms it went. A delete can be refused like a write (locked keychain,
    /// denied prompt, MDM policy); assuming success would tell the user a secret is gone while
    /// every scan still uses it.
    private func removeKey() {
        let refusal = APIKeyRemoval.remove()
        apiKeyField = ""
        revealedKey = nil
        isReplacingKey = false
        hasStoredKey = refusal != nil
        if refusal == nil { SettingsWindowLog.log("intelligence.apiKey", "removed") }
        // `.invalid` renders its message verbatim; `.failed` would prefix "Couldn't reach
        // Anthropic" and blame the network for a local refusal. As in `saveTypedKey`.
        keyTestResult = refusal.map { .invalid($0) }
    }

    /// Reads the secret: the one place in Settings that does, so the one that may raise the
    /// Keychain prompt. A refusal is reported, since a row gone blank would read as "no key".
    private func revealKey() {
        switch AnthropicKeychain.readOutcome() {
        case .found(let key):
            revealedKey = key
            keyTestResult = nil
        case .notConfigured:
            // The item went away behind our back: removed in Keychain Access, or a profile change.
            hasStoredKey = false
            revealedKey = nil
        case .unreadable(let status):
            revealedKey = nil
            keyTestResult = .invalid("The Keychain wouldn’t release the key (status \(status)). Unlock your login keychain and try again.")
        }
    }

    /// Copies the revealed key, then clears the pasteboard a minute later, but only if
    /// `changeCount` says nothing else wrote to it meanwhile; otherwise it would wipe the user's
    /// own copy.
    ///
    /// Marked `org.nspasteboard.ConcealedType`, the password managers' convention, because
    /// clipboard-history apps snapshot the pasteboard the instant it changes, long before the wipe,
    /// and well-behaved ones skip concealed items. Universal Clipboard also relays the general
    /// pasteboard to nearby devices.
    private func copyRevealedKey() {
        guard let revealedKey else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // **Declare the marker before the string**: a manager watching `changeCount` reads the
        // types as soon as it sees a change.
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.setString(revealedKey, forType: .string)
        let stamp = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard pasteboard.changeCount == stamp else { return }
            pasteboard.clearContents()
        }
    }

    /// Validates the key in the field (or, if empty, the stored key) with a free Console call. A
    /// revealed key is used over re-reading the Keychain, so the prompt isn't asked twice.
    private func testKey() async {
        let typed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (revealedKey ?? AnthropicKeychain.read() ?? "") : typed
        testingKey = true
        keyTestResult = nil
        let result = await AnthropicKeyCheck.validate(key)
        testingKey = false
        keyTestResult = result
    }
}
