import Design
import Settings
import SwiftUI
import Sync

/// The last screen: every answer, what is running, and the way out.
///
/// Each row can be changed from here. Change finishes setup first, then opens the Settings tab
/// that owns the answer, so the sheet isn't left over the tab it opened. The folder row is the
/// exception: no tab learns a folder, so its Learn goes back to the Learn screen.
struct SummaryScreen: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: SettingsManager
    let hue: LiquidGlassHue
    let onChange: (SettingsView.SettingsTab) -> Void
    let onStartWith: (SetupStart) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            // The badge sits on the title's line, not beside the whole block, so the heading
            // starts at the card's inset like every row below it.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(.system(size: 19))
                        .foregroundStyle(hue.accentColor)
                    Text("You’re all set").scaledFont(.title2.weight(.semibold))
                }
                Text("Here is what SyncCloud will do. Change any of it in Settings.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                row("cloud", "Locations: \(locationsSummary)", tab: .providers, verb: "Change")
                Divider()
                // Back to Learn, not out to Settings: no Settings tab learns a folder, and the
                // Countries row below relies on this button to change them.
                row("folder", Self.folderLine(for: model),
                    verb: model.walkState.isDone || model.writtenReport != nil ? "Learn Again" : "Learn",
                    help: "Go back to the Learn screen and read a folder",
                    action: { model.returnToLearn() })
                Divider()
                row("person", "You: \(youSummary)", tab: .people, verb: "Change")
                Divider()
                row("person.2", "People: \(peopleSummary)", tab: .people, verb: "Change")
                if let countries = Self.countriesLine(for: model) {
                    Divider()
                    // No Change link: the confirmed countries live in the profile, and nothing in
                    // Settings edits them. Learning the folder again changes them, via the row
                    // above.
                    row("globe", countries, tab: nil, verb: nil)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))

            if model.walkNotInUse {
                SetupNote(text: SetupFlow.walkNotInUse, systemImage: "exclamationmark.triangle")
            }
            // A folder whose earlier Restructure history could not be brought back: said here,
            // where the folder was just saved, not only in the log.
            if let notice = model.writtenReport?.historyNotice {
                SetupNote(text: notice, systemImage: "exclamationmark.triangle")
            }

            if let manager = model.syncManager {
                SetupSurveyRow(manager: manager,
                               onPause: { Task { await manager.pauseDocumentSurvey() } })
            }

            if !startButtons.isEmpty {
                VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                    Text("Or start with").scaledFont(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        ForEach(startButtons, id: \.start) { button in
                            Button {
                                onStartWith(button.start)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(button.title).scaledFont(.caption.weight(.medium))
                                    Text(button.detail)
                                        .scaledFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(Color.secondary.opacity(0.10)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverAffordance(.segment))
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text(SetupFlow.runAgainNote).scaledFont(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Open Settings") { onChange(.general) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - The rows

    private func row(_ symbol: String, _ text: String,
                     tab: SettingsView.SettingsTab?, verb: String?) -> some View {
        row(symbol, text, verb: tab == nil ? nil : verb,
            help: tab.map { "Finish setup and open Settings ▸ \($0.displayName)" },
            action: tab.map { tab in { onChange(tab) } })
    }

    private func row(_ symbol: String, _ text: String,
                     verb: String?, help: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .scaledFont(.caption)
                .foregroundStyle(hue.accentColor)
                .frame(width: 16)
            Text(text)
                .scaledFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let verb, let action {
                Button(verb, action: action)
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help(help ?? verb)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var locationsSummary: String {
        // The full name, account and all: a summary row is one line, and accounts of one provider
        // listed by provider alone would read "Google Drive, Google Drive".
        let names = settings.enabledProviders.map(\.displayName)
        return names.isEmpty ? "none turned on" : names.joined(separator: ", ")
    }

    /// The folder row: what Save wrote, not what is in memory. A reading not on disk (unsaved,
    /// still running, or finished after Structure) says so; a written profile says what it holds,
    /// even after Learn was skipped on the way back.
    ///
    /// `summaryDoesNotDescribeTheWalkAsUnshipped` pins the not-learned literal.
    static func folderLine(for model: SetupModel) -> String {
        func folders(_ count: Int) -> String {
            count == 1 ? "1 folder" : "\(count.formatted()) folders"
        }
        switch model.walkState {
        case .done(let walk):
            return model.currentReadingIsWritten
                ? "Learned: \(walk.root.lastPathComponent), " + folders(walk.folderCount)
                : "Read \(walk.root.lastPathComponent) — not saved"
        case .running:
            return "Reading \(model.walkRootName) — not saved yet"
        case .idle, .skipped, .failed:
            guard let report = model.writtenReport else {
                return "You have not learned a folder tree yet"
            }
            // The builder counts the root itself as one entry.
            return "Learned: \((report.root as NSString).lastPathComponent), "
                + folders(max(report.foldersProfiled - 1, 0))
        }
    }

    /// The Countries row, or nil when there is nothing to list — the countries Save wrote, or the
    /// ticks in hand marked as not saved.
    static func countriesLine(for model: SetupModel) -> String? {
        func list(_ values: Set<String>) -> String {
            values.isEmpty ? "none" : values.sorted().joined(separator: ", ")
        }
        if model.walkState.isDone, !model.currentReadingIsWritten {
            if model.confirmedCountries.isEmpty, model.writtenCountries?.isEmpty ?? true { return nil }
            return "Countries: \(list(model.confirmedCountries)) — not saved"
        }
        let shown = model.walkState.isDone ? model.confirmedCountries : (model.writtenCountries ?? [])
        return shown.isEmpty ? nil : "Countries: \(list(shown))"
    }

    private var youSummary: String {
        let name = model.draft.yourName.isEmpty ? model.firstName : model.draft.yourName
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "not set" }
        let forms = model.tickedForms.count
        return forms == 0 ? name : "\(name), \(forms) name form\(forms == 1 ? "" : "s")"
    }

    private var peopleSummary: String {
        let names = model.rosterNames
        guard !names.isEmpty else {
            return SetupFlow.peopleSummary(otherCount: 0, rosterIsReadOnly: model.rosterIsReadOnly,
                                           rosterRepeatsAnId: model.rosterRepeatsAnId)
        }
        if model.rosterIsReadOnly {
            return SetupFlow.peopleSummary(otherCount: names.count, rosterIsReadOnly: true,
                                           rosterRepeatsAnId: model.rosterRepeatsAnId)
        }
        return names.prefix(4).joined(separator: ", ")
            + (names.count > 4 ? " and \(names.count - 4) more" : "")
    }

    /// The two ways in that are worth offering, and only when they would work.
    ///
    /// Compare is hidden with only one location on, rather than opening iCloud against itself,
    /// which explains nothing about what Compare is for.
    private var startButtons: [(start: SetupStart, title: String, detail: String)] {
        var out: [(SetupStart, String, String)] = []
        let loose = model.looseRoutes.count
        if loose > 0 {
            out.append((.toFile, "Organize ▸ To File",
                        "\(loose) loose file\(loose == 1 ? "" : "s")"))
        }
        let enabled = settings.enabledProviders
        if enabled.count >= 2 {
            out.append((.compare, "Compare",
                        enabled.prefix(2).map { LocationsScreen.name($0) }.joined(separator: " · ")))
        }
        return out.map { (start: $0.0, title: $0.1, detail: $0.2) }
    }
}

/// The one live row on the Summary screen: how far the document read has got.
///
/// Its own view because it must observe the engine, and the screen doesn't: `SetupModel` holds
/// the manager as a plain reference, so a row reading `documentSurveyProgress` through it would
/// redraw only when something else changed the model, and the counter would freeze. The row takes
/// the manager as an `@ObservedObject`, and exists only where there is one.
struct SetupSurveyRow: View {
    @ObservedObject var manager: FileSyncManager
    /// Stopping is not offered here: this row exists to say the reading is under way and can be
    /// left, and the lens strip carries the full set of verbs.
    var onPause: () -> Void

    var body: some View {
        if let progress = manager.documentSurveyProgress, progress.total > 0, manager.documentSurveySourceRoot == nil {
            HStack(spacing: 8) {
                InlineSpinner()
                Text("Reading documents: \(progress.completed.formatted()) of "
                     + "\(progress.total.formatted()) · continues in Organize")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if !progress.isPaused {
                    Button("Pause", action: onPause)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
