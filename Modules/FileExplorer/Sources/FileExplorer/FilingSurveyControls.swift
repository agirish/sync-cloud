import Design
import SwiftUI
import Sync

/// To File's words about which survey placed the cards (GK–GN, 2026-10-31) — pure, so a test can
/// read them without mounting a view.
public enum FilingSurveyText {

    /// "Dropbox’s", "Documents’".
    public static func possessive(_ name: String) -> String { FilingSurveyInUse.possessive(name) }

    /// The menu's label: whose survey placed these cards.
    public static func menuTitle(_ use: FilingSurveyInUse, primaryName: String) -> String {
        switch use.kind {
        case .primary, .borrowed: return "Using \(possessive(primaryName)) Survey"
        case .own: return "Using Its Own Survey"
        case .byName: return "No Survey"
        }
    }

    /// The borrowed survey's line in the menu, with the measurement that decided it.
    public static func primaryItem(_ use: FilingSurveyInUse, primaryName: String) -> String {
        "\(possessive(primaryName)) Survey — \(use.matchPercent) of folders match"
    }

    public static func ownItem(_ use: FilingSurveyInUse, sourceName: String) -> String {
        let count = use.ownFolderCount.map { " — \($0.formatted()) folders" } ?? ""
        return "\(possessive(sourceName)) Own Survey\(count)"
    }

    /// The strip over a tree placed by name.
    public static func byNameTitle(sourceName: String, primaryName: String) -> String {
        "\(sourceName) is laid out differently from \(primaryName)."
    }

    public static func byNameDetail(_ use: FilingSurveyInUse) -> String {
        "\(use.matched.formatted()) of its \(use.total.formatted()) folders match, so To File is placing "
            + "files by name only. Learning its folders reads folder names and how the files in them "
            + "are named. Nothing downloads."
    }

    public static func learning(sourceName: String) -> String {
        "Learning \(possessive(sourceName)) folders…"
    }

    public static func note(_ note: SourceSurveyNote, sourceName: String) -> String {
        if let failure = note.failure { return "Couldn’t learn \(possessive(sourceName)) folders. \(failure.sentence)" }
        let count = note.learnedFolders.map { "\($0.formatted()) " } ?? ""
        return "Learned \(possessive(sourceName)) \(count)folders. To File now places its files by that layout."
    }
}

/// Which source names a tree — the source holding it most closely — and which names the primary
/// survey's tree, from the sources the workspace was handed.
struct FilingSurveyNames {
    let source: String
    let primary: String

    init(use: FilingSurveyInUse, primaryRoot: String?, sources: [(name: String, root: String)]) {
        source = FilingSurveyInUse.sourceName(for: use.root, sources: sources)
            ?? (use.root as NSString).lastPathComponent
        primary = primaryRoot.flatMap { FilingSurveyInUse.sourceName(for: $0, sources: sources) } ?? "iCloud"
    }
}

/// Row 2's survey menu: names the survey that placed the cards and lets the user choose another
/// for this source. Absent for the primary survey's own tree, where there is nothing to choose.
struct FilingSurveyMenu: View {
    @ObservedObject var syncManager: FileSyncManager
    let sources: [(name: String, root: String)]
    /// Scans again, so the cards follow the survey just chosen or learned.
    let onRescan: () -> Void

    var body: some View {
        if let use = syncManager.filingSurveyInUse, use.kind != .primary {
            let names = FilingSurveyNames(use: use, primaryRoot: syncManager.filingFolderProfile?.recordedFolderPath,
                                          sources: sources)
            Menu {
                Section("Placing \(FilingSurveyText.possessive(names.source)) files with") {
                    Toggle(FilingSurveyText.primaryItem(use, primaryName: names.primary), isOn: Binding(
                        get: { use.kind == .borrowed },
                        set: { if $0 { choose(.primary, root: use.root) } }))
                    if use.ownProfileId != nil {
                        Toggle(FilingSurveyText.ownItem(use, sourceName: names.source), isOn: Binding(
                            get: { use.kind == .own },
                            set: { if $0 { choose(.own, root: use.root) } }))
                    }
                }
                Divider()
                Button(use.ownProfileId == nil ? "Learn \(FilingSurveyText.possessive(names.source)) Own Folders"
                                               : "Learn Its Folders Again") {
                    learn(root: use.root)
                }
                .disabled(syncManager.learningSourceSurveyRoot != nil)
                .help("Reads folder names and how the files in them are named. Nothing downloads.")
            } label: {
                Label(FilingSurveyText.menuTitle(use, primaryName: names.primary), systemImage: "map")
                    .scaledFont(.system(size: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.hoverAffordance(.inline))
            .fixedSize()
            .help(helpText(use, names: names))
        }
    }

    private func helpText(_ use: FilingSurveyInUse, names: FilingSurveyNames) -> String {
        switch use.kind {
        case .primary: return ""
        case .borrowed:
            return "\(names.source) uses \(FilingSurveyText.possessive(names.primary)) survey: "
                + "\(use.matched.formatted()) of its \(use.total.formatted()) folders match."
        case .own: return "\(names.source) uses the survey learned from its own folders."
        case .byName: return FilingSurveyText.byNameDetail(use)
        }
    }

    private func choose(_ choice: SourceSurveyChoice, root: String) {
        syncManager.setSourceSurveyChoice(root: root, choice)
        onRescan()
    }

    private func learn(root: String) {
        Task {
            if case .success = await syncManager.learnSourceSurvey(root: root) { onRescan() }
        }
    }
}

/// The strip under To File's header for a tree placed by name (GL): what is happening, and Learn
/// Its Folders. Also says what Learn did, until dismissed or another tree is scanned.
struct FilingSurveyStrip: View {
    @ObservedObject var syncManager: FileSyncManager
    let sources: [(name: String, root: String)]
    let accent: Color
    let onRescan: () -> Void

    static func isShown(_ manager: FileSyncManager) -> Bool {
        manager.learningSourceSurveyRoot != nil || manager.sourceSurveyNote != nil
            || manager.filingSurveyInUse?.kind == .byName
    }

    var body: some View {
        if let use = syncManager.filingSurveyInUse, Self.isShown(syncManager) {
            let names = FilingSurveyNames(use: use, primaryRoot: syncManager.filingFolderProfile?.recordedFolderPath,
                                          sources: sources)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if syncManager.learningSourceSurveyRoot != nil {
                    InlineSpinner()
                    Text(FilingSurveyText.learning(sourceName: names.source))
                        .scaledFont(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 8)
                } else if let note = syncManager.sourceSurveyNote {
                    Image(systemName: note.failure == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(note.failure == nil ? SemanticColor.success : SemanticColor.caution)
                    Text(FilingSurveyText.note(note, sourceName: names.source))
                        .scaledFont(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        syncManager.dismissSourceSurveyNote()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                } else {
                    Image(systemName: "map")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FilingSurveyText.byNameTitle(sourceName: names.source, primaryName: names.primary))
                            .scaledFont(.system(size: 11, weight: .semibold))
                        Text(FilingSurveyText.byNameDetail(use))
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Use \(FilingSurveyText.possessive(names.primary)) Anyway") {
                        syncManager.setSourceSurveyChoice(root: use.root, .primary)
                        onRescan()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .scaledFont(.system(size: 11))
                    .help("Place \(FilingSurveyText.possessive(names.source)) files with \(FilingSurveyText.possessive(names.primary)) survey, as if it were laid out the same.")
                    Button("Learn Its Folders") {
                        Task {
                            if case .success = await syncManager.learnSourceSurvey(root: use.root) { onRescan() }
                        }
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .help("Reads folder names and how the files in them are named — a few seconds. Nothing downloads.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(syncManager.sourceSurveyNote?.failure != nil
                        ? AnyShapeStyle(SemanticColor.caution.opacity(0.10))
                        : AnyShapeStyle(accent.opacity(0.10)))
            .accessibilityElement(children: .contain)
        }
    }
}
