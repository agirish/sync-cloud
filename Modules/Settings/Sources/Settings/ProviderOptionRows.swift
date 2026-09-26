import AppKit
import Design
import SwiftUI
import Sync

/// The two per-location preferences: what it is called, and where a pane opens inside it.
///
/// **Extracted so setup and Settings are the same control, not two spellings of it.** The guided
/// setup sheet offers these under *More options* on its Locations screen; Settings ▸ Sources offers
/// them inside a location's disclosure. They commit identically — Return or focus-loss for the
/// name, a refusal line under the picker for a folder outside the root — because they are one view.
///
/// The `SettingsRow`/`Toggle` titles are the same literals they were inside
/// ``ProviderSettingsSection``, so `SettingsSearchTests.everyControlLabelInTheTabSourcesIsIndexed`
/// still finds them; the file sits directly in `Sources/Settings/` because that scan reads one
/// level of the directory and nothing below it.
public struct ProviderOptionRows: View {
    @ObservedObject var settings: SettingsManager
    let provider: CloudProvider
    /// Whether to draw the "Open at" row. Setup shows it; a folder source has no landing folder
    /// distinct from its root, so Settings hides it there.
    var showsOpenAt: Bool

    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool
    /// Why the last "Open at" pick was declined, or nil when none was. A picker that simply did
    /// nothing would look broken rather than principled.
    @State private var openAtRefusal: String?

    public init(settings: SettingsManager, provider: CloudProvider, showsOpenAt: Bool = true) {
        self.settings = settings
        self.provider = provider
        self.showsOpenAt = showsOpenAt
    }

    private var isEnabled: Bool { settings.isEnabled(provider.id) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            nameRow
            if showsOpenAt, !provider.isLocalFolder { openAtRow }
        }
        .onAppear {
            draftName = provider.displayName
            // A refusal is about one edit, not about the row. Re-mounting starts clean.
            openAtRefusal = nil
        }
        .onChange(of: provider.displayName) { _, updated in
            if !nameFieldFocused && draftName != updated { draftName = updated }
        }
    }

    // MARK: - The name

    private var nameRow: some View {
        SettingsRow("Display name") {
            TextField("Provider name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 200)
                .focused($nameFieldFocused)
                .onSubmit { commitName() }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitName() }
                }
                .help("Clear the name to restore the default.")
        }
    }

    private func commitName() {
        let normalized = ProviderFieldEdit.normalized(draftName)
        guard ProviderFieldEdit.shouldCommit(draft: normalized, committed: provider.displayName) else {
            draftName = normalized
            return
        }
        // Empty clears the override; the default name flows back through discovery.
        settings.setCustomName(normalized, for: provider.id)
        draftName = normalized.isEmpty ? provider.displayName : normalized
    }

    // MARK: - Where panes open

    private var openAtRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow("Open at") {
                HStack(spacing: 8) {
                    // **Monospaced only when it is a path.** "The source root" is an English
                    // sentence standing in for a value, and setting it in the same face as a real
                    // path says it is one.
                    Text(openAtDisplay)
                        .scaledFont(provider.openAt.isEmpty ? .callout
                                                            : .system(.callout, design: .monospaced))
                        .foregroundStyle(provider.openAt.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { selectOpenAtDirectory() }
                        .controlSize(.small)
                    Button("Reset") {
                        openAtRefusal = nil
                        settings.resetOpenAt(for: provider.id)
                    }
                    .controlSize(.small)
                    .disabled(!settings.hasOpenAtOverride(for: provider.id))
                }
                .disabled(!isEnabled)
            }

            // Both, not `else if`. The missing-folder note is a standing fact about the location
            // and the refusal is about the click just made; shadowing the first behind the second
            // hid "your landing folder is gone" until the row was re-mounted.
            if !provider.openAt.isEmpty, settings.isPathValid(for: provider.id),
               !settings.isLandingValid(for: provider.id) {
                note("That folder isn't there any more, so panes open at the root instead.")
            }
            if let openAtRefusal {
                note(openAtRefusal)
                    .accessibilityLabel("Opening folder not changed. \(openAtRefusal)")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .scaledFont(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The landing folder as the row shows it — the root-relative path, or a phrase for the root.
    ///
    /// A phrase rather than a blank line: `""` is a real, chosen value here, and panes on this
    /// location do open somewhere.
    private var openAtDisplay: String {
        provider.openAt.isEmpty ? "The source root" : provider.openAt
    }

    private func selectOpenAtDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder \(provider.displayName) opens at"
        panel.prompt = "Open at"
        // Through the manager, not `provider.landingPath`: the value type joins root and `openAt`
        // unconditionally, while the manager degrades to the root when the landing folder is not
        // there.
        panel.directoryURL = URL(
            fileURLWithPath: (settings.landingPath(for: provider.id) as NSString).expandingTildeInPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openAtRefusal = OpenAtRefusal.message(settings.setOpenAt(url.path, for: provider.id),
                                              provider: provider.displayName)
    }
}

/// What the app says when a landing folder is declined.
///
/// **One vocabulary, two rows.** Settings ▸ Sources and setup's Locations screen both offer this
/// pick, and a refusal worded differently in the two places is the same defect as a rule
/// implemented twice — the user reads one of them and learns the wrong thing about the other.
public enum OpenAtRefusal {
    public static func message(_ outcome: PathChangeOutcome,
                               provider: String) -> String? {
        switch outcome {
        case .changed, .unchanged:
            return nil
        case .refusedOutsideRoot:
            return "That folder is outside \(provider). Pick one inside the root shown above."
        case .refusedUnknownSource:
            return "\(provider) isn't available right now, so its opening folder wasn't changed."
        case .refusedDuplicate:
            // Unreachable from this picker — a landing folder is not a source and cannot collide
            // with one — but named rather than defaulted, so adding a case to the enum keeps
            // failing here until someone decides what these rows should say about it.
            return "That folder couldn't be used as \(provider)'s opening folder."
        }
    }
}

/// Which provider's folder-name rules names are checked against.
///
/// **One global control, not a per-location one**, which is why it is extracted on its own: the
/// rule applies to every name the app checks, wherever it came from.
public struct FolderNameRuleRow: View {
    @ObservedObject var settings: SettingsManager

    public init(settings: SettingsManager) {
        self.settings = settings
    }

    public var body: some View {
        SettingsRow("Check folder names against") {
            Picker("Check folder names against", selection: $settings.folderNameRule) {
                ForEach(FolderNameRuleOption.all) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// The two filing preferences setup offers under *More options* on its Learn screen.
///
/// **The same two keys Settings ▸ Organize and Settings ▸ Intelligence write**, read through the
/// same constants rather than re-declared: the inbox folder is what the walk marks as refusing
/// files, and the on-device pass is what Organize uses when a name alone is not enough. Both are
/// live the moment they are touched, exactly as they are in Settings.
public struct InboxAndSuggestionRows: View {
    @ObservedObject var settings: SettingsManager

    @AppStorage(GeneralSettings.filingInboxRelativePathKey) private var filingInbox: String = "TODO"
    @AppStorage(FileSyncManager.usesAIDefaultsKey) private var filingUseAI: Bool = true

    public init(settings: SettingsManager) {
        self.settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow("Loose-files inbox") {
                // The placeholder is "None", not the key's default: a field deliberately emptied
                // has to look different from one never touched.
                TextField("None", text: $filingInbox)
                    .frame(width: 160)
                    .multilineTextAlignment(.trailing)
            }
            .help("The folder (relative to the location's root) where loose files pile up — e.g. “TODO”. Nothing is filed into it.")
            Toggle("Suggest folders with on-device AI (Apple Intelligence)", isOn: $filingUseAI)
                .toggleStyle(.checkbox)
        }
    }
}
