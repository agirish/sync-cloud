import Design
import Settings
import SwiftUI
import Sync

/// Screen 1: the cloud folders SyncCloud found, and which of them to use.
///
/// **A confirmation, not a question with a wrong answer.** Everything discovered arrives switched
/// on, so a user who changes nothing has answered correctly — which is why this screen has no Skip:
/// it would be a second spelling of Continue.
struct LocationsScreen: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: SettingsManager
    let hue: LiquidGlassHue

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(
                title: "SyncCloud found \(SetupFlow.spelled(settings.availableProviders.count).lowercased()) "
                    + "location\(settings.availableProviders.count == 1 ? "" : "s") on this Mac",
                blurb: "Switch off any you don't use.")

            if settings.availableProviders.isEmpty {
                SetupNote(text: "No cloud accounts were found in ~/Library/CloudStorage, and iCloud "
                          + "Drive is not set up. Add any folder on this Mac to get started — "
                          + "Compare and Organize work the same over it.")
            } else {
                VStack(spacing: 0) {
                    ForEach(settings.availableProviders) { provider in
                        row(provider)
                        if provider.id != settings.availableProviders.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Color.secondary.opacity(0.06)))
            }

            HStack(spacing: 8) {
                Button("Add Folder…") { model.addFolderSource() }.controlSize(.small)
                Button(model.isRefreshingProviders ? "Refreshing…" : "Refresh") {
                    model.refreshProviders()
                }
                .controlSize(.small)
                .disabled(model.isRefreshingProviders)
                Spacer()
                Text("\(settings.enabledProviders.count) of \(settings.availableProviders.count) on")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("Missing one? Add Folder… takes any folder on this Mac.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)

            SetupMoreOptions(subtitle: "Display name · starting folder · folder-name rule") {
                // **Each location says which one it is.** The rows are identical from the outside —
                // a name field and a folder — so nine of them in a row is nine chances to edit the
                // wrong account's settings.
                ForEach(settings.enabledProviders) { provider in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            ProviderLogo(provider.imageName, capHeight: 12)
                            Text(Self.name(provider)).scaledFont(.caption.weight(.semibold))
                            Text(Self.detail(provider))
                                .scaledFont(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        ProviderOptionRows(settings: settings, provider: provider)
                            .padding(.leading, 20)
                    }
                }
                Divider().opacity(0.4)
                FolderNameRuleRow(settings: settings)
            }

            Spacer(minLength: 0)
        }
    }

    private func row(_ provider: CloudProvider) -> some View {
        let isEnabled = settings.isEnabled(provider.id)
        let isValid = settings.isPathValid(for: provider.id)
        return HStack(spacing: 11) {
            ProviderLogo(provider.imageName, capHeight: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(Self.name(provider))
                        .scaledFont(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // **The badge appears only when something is wrong.** A list where every row is
                    // decorated has no way left to point at a row.
                    if !isValid {
                        Text("Can't be found")
                            .scaledFont(.caption2.weight(.medium))
                            .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.caution))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(SemanticColor.caution.opacity(0.16)))
                    }
                }
                Text(Self.detail(provider))
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(provider.rootPath)
            }
            Spacer(minLength: 10)

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { settings.setEnabled($0, for: provider.id); model.reconcilePrimary() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(isEnabled && !settings.canDisable(provider.id))
                .help(isEnabled && !settings.canDisable(provider.id)
                      ? SettingsManager.ProviderToggleHelp.lastRemaining
                      : SettingsManager.ProviderToggleHelp.offer(provider.displayName))
                .accessibilityLabel(Self.name(provider))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .opacity(isEnabled ? 1 : 0.5)
    }

    /// The provider's name without the account in it.
    ///
    /// **The account is what makes these truncate**, and the clipped half is the only part that
    /// tells two Drive accounts apart. The name goes on the first line and the account leads the
    /// second, where it has the width.
    static func name(_ provider: CloudProvider) -> String {
        guard let open = provider.displayName.firstIndex(of: "("),
              provider.displayName.hasSuffix(")") else { return provider.displayName }
        return String(provider.displayName[..<open]).trimmingCharacters(in: .whitespaces)
    }

    /// What identifies this location at a glance — the account for a cloud one, the path for a
    /// folder, whose id is a UUID that says nothing to anyone.
    static func detail(_ provider: CloudProvider) -> String {
        if provider.isLocalFolder { return shortPath(provider.rootPath) }
        guard let open = provider.displayName.firstIndex(of: "("),
              provider.displayName.hasSuffix(")") else { return shortPath(provider.rootPath) }
        return String(provider.displayName[provider.displayName.index(after: open)...].dropLast())
    }

    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// The Why panel beside Locations.
struct LocationsWhy: View {
    let hue: LiquidGlassHue
    let marks: [Mark]

    /// One kind of location, as the panel draws it.
    struct Mark: Hashable, Identifiable {
        let name: String
        /// The asset or SF Symbol the location wears — `CloudProvider.imageName`, the same field
        /// every row on this screen draws from.
        let imageName: String
        var id: String { imageName }
    }

    /// The kinds among a set of locations, in the order they appear, at most `limit` of them.
    ///
    /// **By kind, not by account, and that is the whole reason this is a function.** The panel is a
    /// picture of the idea — *these are your providers' own folders, and SyncCloud reads them where
    /// they are* — while the list of accounts is the column to its left. On this Mac that
    /// distinction is ten locations against four marks: one iCloud, one Dropbox, one OneDrive and
    /// several Google Drive accounts, which wear one mark between them. Drawing the first three
    /// *accounts* instead showed iCloud, Dropbox and OneDrive and silently dropped Google Drive —
    /// the provider whose folder is open in the other pane.
    static func marks(for providers: [CloudProvider], limit: Int = 4) -> [Mark] {
        var seen: Set<String> = []
        var out: [Mark] = []
        for provider in providers where seen.insert(provider.imageName).inserted {
            out.append(Mark(name: LocationsScreen.name(provider), imageName: provider.imageName))
            if out.count == limit { break }
        }
        return out
    }

    /// The marks in one row, each with its name under it.
    ///
    /// **One row, because four kinds is the common case and the fourth was falling off.** Wrapped,
    /// the strip put iCloud, Dropbox and OneDrive on the first line and left Google Drive alone on
    /// the second — a ragged orphan under a heading, on the provider this Mac uses most.
    ///
    /// **Then the row itself broke, and the reason was not in this view.** With four names sharing
    /// the panel, a name too wide for its cell wraps — and SwiftUI wraps *inside a word* when the
    /// cell is narrower than the word. At 135% the strip read "iCloud", "OneDri/ve",
    /// "Google/Drive", "Dropb/ox": two of the four split mid-word. Nothing here could have fixed
    /// that, because the cause was `SetupWhyMetrics.width` — a constant 250 in a card that grows
    /// with the text, so raising the size put 35% more type in the same column. The column is a
    /// share of the card now, and the cells have room for their words at every size;
    /// `noProviderNameHasToShrinkToFit` is what keeps it that way as providers are added.
    ///
    /// `minimumScaleFactor` was tried instead and was worse than the wrap it replaced: at the old
    /// width "Google Drive" shrank and *still* truncated, so the row carried three names at one
    /// size and a fourth, smaller, reading "Google Dr…". A name that wraps at its own space stays
    /// the name.
    ///
    /// Its own view so `theMarkStripStaysOnOneRow` can lay it out and measure it, which is the only
    /// way to know whether it wrapped.
    struct MarkStrip: View {
        let marks: [Mark]

        @Environment(\.appFontScale) private var fontScale

        /// The marks and their gaps follow the card's geometry, not the text scale — the card does
        /// not shrink when the type does, and neither should they.
        private var scale: CGFloat { SetupSheetMetrics.chromeScale(fontScale) }

        /// The mark's cap height at the default text size — smaller than the list's 20, because
        /// this is an illustration beside prose rather than a row's leading element.
        static let baseCapHeight: CGFloat = 18

        /// The gap between the mark and its name, and between one cell and the next.
        static let baseGap: CGFloat = 3
        static let baseSpacing: CGFloat = 6

        var body: some View {
            HStack(alignment: .top, spacing: Self.baseSpacing * scale) {
                ForEach(marks) { mark in
                    VStack(spacing: Self.baseGap * scale) {
                        ProviderLogo(mark.imageName, capHeight: Self.baseCapHeight * scale)
                        Text(mark.name)
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }

        /// The width one cell gets in a panel at this text size.
        static func cellWidth(_ count: Int, scale: CGFloat) -> CGFloat {
            let geo = SetupSheetMetrics.chromeScale(scale)
            let gaps = baseSpacing * geo * CGFloat(count - 1)
            return (SetupWhyMetrics.textWidth(scale: scale) - gaps) / CGFloat(count)
        }
    }

    /// What the panel shows before any location has been discovered.
    static let fallback: [Mark] = [
        Mark(name: "iCloud Drive", imageName: "icloud"),
        Mark(name: "Google Drive", imageName: "googledrive"),
        Mark(name: "Dropbox", imageName: "dropbox"),
        Mark(name: "OneDrive", imageName: "onedrive"),
    ]

    var body: some View {
        SetupWhyPanel(footnoteLead: "If you change nothing:",
                      footnote: "every location stays on.",
                      hue: hue) {
            VStack(alignment: .leading, spacing: 8) {
                // **The brand mark, not a tinted `cloud.fill`.** Every row on this screen draws
                // `ProviderLogo(provider.imageName)`, and the panel drew one SF Symbol for all of
                // them in whatever tint `ProviderHue` gave the name — so Dropbox's folded box and
                // OneDrive's twin lobes both came out as the same cloud, two inches from their own
                // logos.
                MarkStrip(marks: marks)
                .accessibilityHidden(true)
                Text("Each provider's own app keeps these folders in sync. SyncCloud reads them in "
                     + "place: nothing is copied, moved or deleted until you ask.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Switching one off only hides it. Nothing on disk changes.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
