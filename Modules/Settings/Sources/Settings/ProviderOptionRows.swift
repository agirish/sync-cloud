import AppKit
import Design
import SwiftUI
import Sync

/// The two per-location preferences: what it is called, and where a pane opens inside it.
///
/// Setup's (*More options* on its Locations screen). Settings ▸ Sources draws its own rows but
/// commits the same way, through `ProviderFieldEdit.commitName` and `OpenAtPicker`: Return or
/// focus-loss for the name, a refusal line under the picker for a folder outside the root.
///
/// `SettingsSearchTests.everyControlLabelInTheTabSourcesIsIndexed` reads the `SettingsRow` and
/// `Toggle` titles, and only one level of `Sources/Settings/`, so this file must stay directly in it.
public struct ProviderOptionRows: View {
    @ObservedObject var settings: SettingsManager
    let provider: CloudProvider
    /// Whether to draw the "Open at" row. Setup shows it; a folder source has no landing folder
    /// distinct from its root, so Settings hides it there.
    var showsOpenAt: Bool

    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool
    /// Why the last "Open at" pick was declined, or nil. A picker that silently did nothing would
    /// look broken.
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
        draftName = ProviderFieldEdit.commitName(draftName, provider: provider, settings: settings)
    }

    // MARK: - Where panes open

    private var openAtRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow("Open at") {
                HStack(spacing: 8) {
                    // Monospaced only when it is a path: "The source root" is a phrase, and a
                    // path's face would claim it is one.
                    Text(openAtDisplay)
                        .scaledFont(provider.openAt.isEmpty ? .callout
                                                            : .system(.callout, design: .monospaced))
                        .foregroundStyle(provider.openAt.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { selectOpenAtDirectory() }
                        .controlSize(.small)
                        .help("Picks the folder inside \(provider.displayName) that panes open at.")
                    Button("Reset") {
                        openAtRefusal = nil
                        settings.resetOpenAt(for: provider.id)
                    }
                    .controlSize(.small)
                    .disabled(!settings.hasOpenAtOverride(for: provider.id))
                    .help("Forgets the folder you chose, so panes open at \(provider.displayName)’s default folder again.")
                }
                .disabled(!isEnabled)
            }

            // Both, not `else if`: the missing-folder note is a standing fact about the location,
            // the refusal is about the last click, and one must not hide the other.
            if !provider.openAt.isEmpty, settings.isPathValid(for: provider.id),
               !settings.isLandingValid(for: provider.id) {
                note("That folder isn’t there any more, so panes open at the root instead.")
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

    /// The landing folder as the row shows it: the root-relative path, or a phrase for the root,
    /// since `""` is a real, chosen value and panes do open somewhere.
    private var openAtDisplay: String {
        provider.openAt.isEmpty ? "The source root" : provider.openAt
    }

    private func selectOpenAtDirectory() {
        guard let outcome = OpenAtPicker.choose(provider: provider, settings: settings) else { return }
        openAtRefusal = OpenAtRefusal.message(outcome, provider: provider.displayName)
    }
}

/// The "Open at" pick, for both rows that offer it, Settings ▸ Sources and setup's Locations screen.
enum OpenAtPicker {
    /// Picks the folder panes on this source open at, and stores it. The panel starts inside the
    /// root, but macOS lets the user navigate anywhere, so containment is enforced on the answer.
    /// - Returns: How the store went, or nil when cancelled.
    @MainActor
    static func choose(provider: CloudProvider, settings: SettingsManager) -> PathChangeOutcome? {
        // Through the manager, not `provider.landingPath`: the manager falls back to the root when
        // the landing folder is gone. Otherwise the panel opens wherever macOS last was, likely
        // outside the root, and the first pick is refused. `SetupSheet.seedWalkRoot` does the same.
        guard let url = NativeAlerts.chooseFolder(
            prompt: "Open at", message: "Choose the folder \(provider.displayName) opens at",
            startingAt: URL(fileURLWithPath: (settings.landingPath(for: provider.id) as NSString).expandingTildeInPath))
        else { return nil }
        return settings.setOpenAt(url.path, for: provider.id)
    }
}

/// What the app says when a landing folder is declined.
///
/// One vocabulary for both rows that offer this pick, Settings ▸ Sources and setup's Locations
/// screen, so a refusal reads the same in each.
public enum OpenAtRefusal {
    public static func message(_ outcome: PathChangeOutcome,
                               provider: String) -> String? {
        switch outcome {
        case .changed, .unchanged:
            return nil
        case .refusedOutsideRoot:
            return "That folder is outside \(provider). Pick one inside the root shown above."
        case .refusedUnknownSource:
            return "\(provider) isn’t available right now, so its opening folder wasn’t changed."
        case .refusedDuplicate:
            // Unreachable here, since a landing folder isn't a source and can't collide with one.
            // Named rather than defaulted, so a new enum case fails to compile here until someone
            // decides what these rows say.
            return "That folder couldn’t be used as \(provider)’s opening folder."
        }
    }
}

/// Which provider's folder-name rules names are checked against.
///
/// One global control, not per location: the rule applies to every name the app checks. Setup's
/// Locations screen and Settings ▸ Sources ▸ Name Checks both draw it.
public struct FolderNameRuleRow: View {
    @ObservedObject var settings: SettingsManager
    /// Whether a change writes Settings' change line: in the Settings window, not in setup.
    private let logsChanges: Bool

    public init(settings: SettingsManager, logsChanges: Bool = false) {
        self.settings = settings
        self.logsChanges = logsChanges
    }

    public var body: some View {
        SettingsRow("Check folder names against") {
            Picker("Check folder names against",
                   selection: logsChanges ? $settings.folderNameRule.loggingSettingsChange("sources.folderNameRule")
                                          : $settings.folderNameRule) {
                ForEach(FolderNameRuleOption.all) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help(
                "A folder accepts any name, so “risky name” has no meaning until you say where the files are headed. Organize and the pane badges check names under a folder source against this."
            )
        }
    }
}

/// The two filing preferences setup offers under *More options* on its Learn screen.
///
/// The same two keys Organize ▸ To File and Organize ▸ Suggestions write, through the same
/// constants: the inbox folder, which the walk marks as refusing files, and the on-device pass
/// Organize uses when a name alone isn't enough. Both take effect at once, as in Settings.
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
                // "None", not the key's default, so a field emptied on purpose looks different
                // from one never touched.
                TextField("None", text: $filingInbox)
                    .frame(width: 160)
                    .multilineTextAlignment(.trailing)
            }
            .help("The folder (relative to the location’s root) where loose files pile up — e.g. “TODO”. Nothing is filed into it.")
            Toggle("Suggest folders with Apple Intelligence", isOn: $filingUseAI)
                .toggleStyle(.checkbox)
                .help("Lets Organize ask the on-device model where files belong. Off, or where it isn’t available, Organize suggests from names and metadata alone.")
        }
    }
}
