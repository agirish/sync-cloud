import Design
import Settings
import SwiftUI
import Sync

/// Screen 2: the folder SyncCloud reads, and the only disclosure in the sheet that matters.
///
/// **The disclosure is drawn here, above the button that does the reading.** It was once made on
/// the screen *after* the walk had already run, which is not a disclosure; the notes are drawn from
/// ``SetupFlow/surveyPrivacyNote`` and ``SetupFlow/surveyThirdPartyNote`` verbatim, because a
/// paraphrase of them has already lost four of the five things the app promises.
struct LearnScreen: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: SettingsManager
    let hue: LiquidGlassHue

    private var providerName: String {
        model.primaryProvider.map { LocationsScreen.name($0) } ?? "this Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "Which folder should SyncCloud learn from?",
                         blurb: "It reads folder and file names only, then shows you what it found.")

            HStack(spacing: 11) {
                Image(systemName: "folder")
                    .scaledFont(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.walkRoot == nil ? "No folder chosen yet" : model.walkRootName)
                        .scaledFont(.callout.weight(.medium))
                    if model.walkRoot != nil {
                        Text("in \(providerName)")
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text(model.walkRootDisplay)
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.walkRoot?.path ?? "")
                    }
                }
                Spacer(minLength: 8)
                // A bare pick: the Learn button below is what reads, and it says so.
                Button("Change…") { model.chooseWalkRoot() }.controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))

            Text("One folder, not a whole account. Documents is usually the right one.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("What it shows you next").scaledFont(.callout.weight(.semibold))
                ForEach(SetupFlow.outline.filter { $0.screen.number ?? 0 >= 3 }, id: \.screen) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.screen.number.map(String.init) ?? "·")
                            .scaledFont(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                            .frame(width: 14, alignment: .trailing)
                        Text(Self.preview(of: row.screen)).scaledFont(.callout)
                    }
                }
                Text("Then a screen showing how you file, so you can correct it before SyncCloud "
                     + "relies on it.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupMoreOptions(subtitle: "Inbox folder name · on-device suggestions") {
                InboxAndSuggestionRows(settings: settings)
            }

            Spacer(minLength: 0)

            // **Above the button, always.** `theDisclosureIsDrawnOnTheStepThatAsksForIt` pins the
            // gate, this pair of notes and their order against the button below.
            if SetupFlow.disclosureScreen == .learn {
                // **One hanging indent for both paragraphs, not a `Label` and then a bare
                // `Text`.** A `Label` indents its wrapped lines under the title; the paragraph
                // after it started at the container's own edge, so the disclosure — the most
                // carefully worded thing on the sheet — was drawn with two different left margins
                // one line apart.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(SetupFlow.surveyPrivacyNote)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(SetupFlow.surveyThirdPartyNote)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// What each later screen will ask, said in the terms this screen has: it has not read
    /// anything yet, so it describes the question rather than the answer.
    static func preview(of screen: SetupFlow.Screen) -> String {
        switch screen {
        case .you: return "Your name, as the folders use it"
        case .people: return "Who else your folders name"
        case .countries: return "Which short names are countries"
        default: return screen.displayName
        }
    }
}

/// The Why panel beside Learn.
struct LearnWhy: View {
    let hue: LiquidGlassHue
    let folderName: String

    var body: some View {
        SetupWhyPanel(footnoteLead: "If you skip:",
                      footnote: "nothing is learned. You can still add people by hand. Countries "
                          + "and Structure are skipped, and Organize files by folder name alone.",
                      hue: hue) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderName).scaledFont(.caption.weight(.semibold))
                    ForEach(Self.examples, id: \.0) { example in
                        HStack(spacing: 4) {
                            Text(example.0).scaledFont(.caption2).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .scaledFont(.system(size: 7))
                                .foregroundStyle(.tertiary)
                            Text(example.1).scaledFont(.caption2).foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityHidden(true)
                Text("Organize suggests where a file belongs by copying how you already file: "
                     + "country inside topic, year at the bottom. It learns that shape here.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Three routings, drawn rather than described. Illustrative, and the panel says so by putting
    /// them under the folder's own name rather than presenting them as findings.
    static let examples: [(String, String)] = [
        ("bill.pdf", "Water/2026"),
        ("statement.pdf", "Finance"),
        ("letter.pdf", "School"),
    ]
}
