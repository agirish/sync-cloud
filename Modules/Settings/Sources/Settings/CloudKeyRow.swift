import AppKit
import Design
import Security
import SwiftUI
import Sync

/// Which shape the Anthropic key row is wearing.
///
/// Split out as a value so the row's behaviour is assertable without rendering it — the states
/// are what the whole control is, and getting the transitions wrong is how the old row ended up
/// with no labelled way to replace a key.
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
        // Replacing wins over everything: the user asked for the field, so the field is what
        // they get even though a key is still stored (and even if it was on screen a moment ago).
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
/// plus Test, Replace…, Remove and the status line.
///
/// It used to be one `SecureField` whose placeholder flipped to "•••• key saved", with Save /
/// Test / Clear beside it. Replacing the key worked — type a new one and press Save — but
/// nothing said so, `Clear` (which deletes) was the only labelled way out, and there was no way
/// to check *which* key was stored.
///
/// Lifted out of `TidySettingsTab` because it owns five pieces of state and all of the Keychain
/// contact in Settings; leaving it inline meant none of that could be exercised on its own.
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

    /// Answers "is a key stored?" when the row appears. Injectable because the default reaches
    /// the real login Keychain, which a render or a test must not depend on — and because
    /// `onAppear` would otherwise overwrite any state a caller passed in.
    private let probeStoredKey: () -> Bool

    /// Starting state. The app uses the defaults — the row seeds itself from the Keychain on
    /// appear — and callers that need a particular state (previews, layout checks) pass one in
    /// along with a matching probe.
    init(
        hasStoredKey: Bool = false,
        revealedKey: String? = nil,
        isReplacingKey: Bool = false,
        probeStoredKey: @escaping () -> Bool = { AnthropicKeychain.isConfigured }
    ) {
        _apiKeyField = State(initialValue: "")
        _hasStoredKey = State(initialValue: hasStoredKey)
        _revealedKey = State(initialValue: revealedKey)
        _isReplacingKey = State(initialValue: isReplacingKey)
        self.probeStoredKey = probeStoredKey
    }

    private var state: CloudKeyRowState {
        .resolve(hasStoredKey: hasStoredKey, isRevealed: revealedKey != nil, isReplacing: isReplacingKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isEntry { keyEntryRow } else { storedKeyRow }

            keyStatusLine

            if state.isEntry {
                Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                    Text("Get a key from the Anthropic Console ↗").scaledFont(.caption)
                }
            }
        }
        .onAppear {
            // The default probe is `isConfigured`, not `hasKey`: the resting state only needs to
            // know whether a key is stored, and reading the secret here is what used to make
            // opening this tab raise the Keychain password prompt.
            hasStoredKey = probeStoredKey()
        }
        // Belt and braces over the fact that leaving the tab already destroys this state: a
        // revealed secret must not outlive the view that put it on screen.
        .onDisappear { revealedKey = nil }
    }

    // MARK: - The two shapes

    /// A stored key: masked or revealed, then the actions.
    ///
    /// Masked, the key sits on one line beside the buttons. Revealed, it takes the full width and
    /// the buttons drop beneath it — because beside four buttons the box is ~330pt, and a real
    /// key is ~108 characters, so *no* line count fits one there. A reveal that shows you half
    /// the key isn't a reveal. The wider shape only exists while the key is on screen; the
    /// resting state stays the single row it was.
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
                    // A ceiling, not a target: a ~108-character key takes two lines of the full
                    // width, and the third is headroom so a longer one grows instead of losing
                    // its middle. Middle truncation is the backstop past that, and it keeps the
                    // prefix and tail — the parts that identify which key this is.
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    // Selectable, so the key can also be taken by hand rather than by Copy.
                    .textSelection(.enabled)
            } else {
                // A fixed run of dots, not one per character: the real key is ~100 characters and
                // drawing one dot each would publish its length for nothing.
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
            Button("Remove", action: removeKey)
                .help("Delete the key from your Keychain.")
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
                Button("Save", action: saveTypedKey)
                    .disabled(!canSave)
                testButton
                if isReplacingKey {
                    Button("Cancel") {
                        isReplacingKey = false
                        apiKeyField = ""
                        // The verdict described the candidate, which is now discarded. Left
                        // standing it reappears above the STORED key's row as though it were
                        // about that key — so "Key rejected (401)" from a mistyped replacement
                        // ends up accusing the key that is actually saved and working.
                        // `Replace…` clears it on the way in for the same reason.
                        keyTestResult = nil
                    }
                }
            }
            .controlSize(.small)

            // Only while replacing. On first run the status line below already says what happens
            // without a key, and the section's own caption already says the key lives in the
            // Keychain — a third grey sentence in the same stack is just noise.
            if isReplacingKey {
                Text("Saving replaces the key currently in your Keychain.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var testButton: some View {
        Button { Task { await testKey() } } label: {
            if testingKey { ProgressView().controlSize(.small) } else { Text("Test") }
        }
        // In the entry field, Test checks what you typed, so it needs something typed — including
        // while replacing, where an empty field would otherwise silently test the OLD stored key
        // (and prompt for it) in the middle of replacing it.
        .disabled(testingKey || (state.isEntry && !canSave))
    }

    private var canSave: Bool {
        !apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var keyStatusLine: some View {
        if testingKey {
            Label("Testing…", systemImage: "ellipsis.circle").scaledFont(.caption).foregroundStyle(.secondary)
        } else if let keyTestResult {
            switch keyTestResult {
            case .valid:
                Label("Key works — you’re set.", systemImage: "checkmark.circle.fill").scaledFont(.caption).foregroundStyle(.green)
            case .invalid(let message):
                Label(message, systemImage: "xmark.octagon.fill").scaledFont(.caption).foregroundStyle(.red)
            case .failed(let message):
                Label("Couldn’t reach Anthropic: \(message)", systemImage: "exclamationmark.triangle.fill").scaledFont(.caption).foregroundStyle(.orange)
            }
        } else if state.showsSecret {
            // The one state worth interrupting the usual reassurance for: a secret is on screen.
            Label("Visible until you hide it or leave Settings.", systemImage: "eye")
                .scaledFont(.caption).foregroundStyle(.orange)
        } else if state == .replacing {
            EmptyView()   // the entry row carries its own caption
        } else if hasStoredKey {
            Label("Key saved to Keychain.", systemImage: "checkmark.circle").scaledFont(.caption).foregroundStyle(.secondary)
        } else {
            Text("No key yet — cloud suggestions fall back to the on-device model until you add one.")
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func saveTypedKey() {
        let status = AnthropicKeychain.store(apiKeyField)
        apiKeyField = ""
        // Confirming the write landed only needs the item to exist — reading it back would
        // prompt for permission immediately after the user typed the key in.
        hasStoredKey = AnthropicKeychain.isConfigured
        isReplacingKey = false
        revealedKey = nil
        // A keychain write can fail (locked or denied keychain, an MDM policy). The status line
        // otherwise fell back to "No key yet", which reads as though nothing had been typed
        // rather than as a refused write. `.invalid` renders its message verbatim; `.failed`
        // prefixes "Couldn't reach Anthropic", which would misattribute a local refusal to
        // the network.
        keyTestResult = (status == errSecSuccess && hasStoredKey)
            ? nil
            : .invalid("The Keychain refused to store the key (status \(status)). Unlock your login keychain and try again.")
    }

    /// Deletes the key — and confirms it actually went, rather than assuming.
    ///
    /// A Keychain delete can be refused exactly as a write can (locked keychain, denied prompt, an
    /// MDM policy). This used to set `hasStoredKey = false` unconditionally, so a refused delete
    /// left the row reading "No key yet — cloud suggestions fall back to the on-device model",
    /// while the key was still in the Keychain, still being used by every scan, and back in the UI
    /// at the next launch. That is the mirror image of the invisible failure `saveTypedKey` reports
    /// — and the worse direction, because the user believes a secret is gone when it is not.
    ///
    /// `isConfigured`, not `hasKey`: confirming the item is gone must not ask for the secret.
    private func removeKey() {
        let status = AnthropicKeychain.delete()
        apiKeyField = ""
        revealedKey = nil
        isReplacingKey = false
        hasStoredKey = AnthropicKeychain.isConfigured
        // `.invalid` renders its message verbatim; `.failed` would prefix "Couldn't reach
        // Anthropic" and misattribute a local refusal to the network. Same choice as `saveTypedKey`.
        keyTestResult = hasStoredKey
            ? .invalid("The Keychain refused to delete the key (status \(status)). It is still stored. Unlock your login keychain and try again.")
            : nil
    }

    /// Reads the secret — the one place in Settings that deliberately does, and so the one place
    /// that may raise the Keychain prompt. A refusal is reported rather than swallowed: a row
    /// that went blank after Reveal would read as "there is no key".
    private func revealKey() {
        switch AnthropicKeychain.readOutcome() {
        case .found(let key):
            revealedKey = key
            keyTestResult = nil
        case .notConfigured:
            // The item went away behind our back — removed in Keychain Access, or a profile change.
            hasStoredKey = false
            revealedKey = nil
        case .unreadable(let status):
            revealedKey = nil
            keyTestResult = .invalid("The Keychain wouldn’t release the key (status \(status)). Unlock your login keychain and try again.")
        }
    }

    /// Copies the revealed key, then clears the pasteboard a minute later — but only if nothing
    /// else has written to it since, which `changeCount` is the only reliable way to know.
    /// Clearing unconditionally would wipe whatever the user copied in the meantime.
    private func copyRevealedKey() {
        guard let revealedKey else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(revealedKey, forType: .string)
        let stamp = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard pasteboard.changeCount == stamp else { return }
            pasteboard.clearContents()
        }
    }

    /// Validates the key in the field (or, if empty, the stored key) with a free Console call.
    ///
    /// A revealed key is preferred over re-reading the Keychain: the user has already answered
    /// the prompt once, and asking again for the same secret in the same sitting is noise.
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
