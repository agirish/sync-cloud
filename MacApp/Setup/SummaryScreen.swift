import Design
import Settings
import SwiftUI
import Sync

/// The last screen: every answer, what is running, and the way out.
///
/// **Each row is changeable from here**, because a summary you cannot act on is a receipt. Change
/// finishes setup first and then opens the Settings tab that owns the answer — in that order, so
/// the sheet is not sitting over the tab it just opened.
struct SummaryScreen: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: SettingsManager
    let hue: LiquidGlassHue
    let onChange: (SettingsView.SettingsTab) -> Void
    let onStartWith: (SetupStart) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            // **The badge sits on the title's line, not beside the whole block.** Beside it, the
            // badge pushed the title *and* the sentence under it 31pt in from the card's inset,
            // so the one screen that ends the sheet was also the one screen whose heading did not
            // begin where every row below it begins.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(.system(size: 19))
                        .foregroundStyle(.tint)
                    Text("You're all set").scaledFont(.title2.weight(.semibold))
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
                row("folder", learnedSummary, tab: .filing,
                    verb: model.walkState.isDone ? "Learn again" : "Learn")
                Divider()
                row("person", "You: \(youSummary)", tab: .people, verb: "Change")
                Divider()
                row("person.2", "People: \(peopleSummary)", tab: .people, verb: "Change")
                if !model.confirmedCountries.isEmpty {
                    Divider()
                    // **No Change link, and its absence is the honest answer.** The confirmed
                    // countries live in the profile's own entries; nothing in Settings edits them,
                    // so a link to a tab would be an offer the tab cannot keep. Learning the folder
                    // again is the way to change them, and the row above says so.
                    row("globe", "Countries: \(model.confirmedCountries.sorted().joined(separator: ", "))",
                        tab: nil, verb: nil)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))

            if model.walkNotInUse {
                SetupNote(text: SetupFlow.walkNotInUse, systemImage: "exclamationmark.triangle")
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
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .scaledFont(.caption)
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text(text)
                .scaledFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let verb, let tab {
                Button(verb) { onChange(tab) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var locationsSummary: String {
        // **The full name, account and all.** The Locations screen splits the account onto a second
        // line because it has one; a summary row is one line, and three accounts of one provider
        // listed by provider read as "Google Drive, Google Drive, Google Drive".
        let names = settings.enabledProviders.map(\.displayName)
        return names.isEmpty ? "none turned on" : names.joined(separator: ", ")
    }

    /// **The shipped sentence, kept.** `doneDoesNotDescribeTheWalkAsUnshipped` pins this literal:
    /// it once described the walk as work that had not been built yet, on a screen whose heading
    /// says everything below it is already in effect.
    private var learnedSummary: String {
        guard let walk = model.walkState.walk else {
            return "You have not learned a folder tree yet"
        }
        return "Learned: \(walk.root.lastPathComponent), \(walk.folderCount.formatted()) folders"
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
            return SetupFlow.peopleSummary(otherCount: 0, rosterIsReadOnly: model.rosterIsReadOnly)
        }
        if model.rosterIsReadOnly {
            return SetupFlow.peopleSummary(otherCount: names.count, rosterIsReadOnly: true)
        }
        return names.prefix(4).joined(separator: ", ")
            + (names.count > 4 ? " and \(names.count - 4) more" : "")
    }

    /// The two ways in that are worth offering, and only when they would work.
    ///
    /// Compare is hidden with one location enabled rather than opening two copies of iCloud, which
    /// is a screen that explains nothing about what Compare is for.
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
/// **Its own view because it has to observe the engine, and the screen does not.** `SetupModel`
/// holds the manager as a plain reference, so a row reading `documentSurveyProgress` through it
/// re-rendered only when something *else* changed the model — the counter would sit at whatever it
/// happened to be when the screen was drawn, on the one screen that exists to report it. The row
/// takes the manager as an `@ObservedObject` instead, and is instantiated only where there is one.
struct SetupSurveyRow: View {
    @ObservedObject var manager: FileSyncManager
    /// Stopping is not offered here: this row exists to say the reading is under way and can be
    /// left, and the lens strip carries the full set of verbs.
    var onPause: () -> Void

    var body: some View {
        if let progress = manager.documentSurveyProgress, progress.total > 0 {
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
