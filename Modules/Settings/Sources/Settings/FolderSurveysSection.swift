import Design
import SwiftUI
import Sync

/// Settings ▸ Organize ▸ Folder surveys: every cloud source and the survey that places its files
/// (GK–GN, 2026-10-31) — the same choices as To File's survey menu, for sources To File has not
/// looked at yet, and the one place a source's own survey is forgotten.
struct FolderSurveysSection: View {
    @ObservedObject var syncManager: FileSyncManager
    /// Cloud sources by name and the folder To File files into for each (its landing folder).
    let sources: [(name: String, root: String)]

    /// What each source uses, measured on appear and after every change here.
    @State private var statuses: [String: FilingSurveyInUse] = [:]
    @State private var forgetting: (name: String, root: String)?
    @State private var generation = 0

    private var primaryRoot: String? { syncManager.filingFolderProfile?.recordedFolderPath }

    private var primaryName: String {
        primaryRoot.flatMap { FilingSurveyInUse.sourceName(for: $0, sources: sources) } ?? "iCloud"
    }

    var body: some View {
        SettingsSection(
            "Folder surveys",
            caption: "What To File knows about each source’s folders. \(FilingSurveyInUse.possessive(primaryName)) "
                + "survey is the primary one: a source laid out like it uses it, and a source laid out "
                + "differently can learn its own. Learning reads folder names only, so nothing downloads."
        ) {
            ForEach(sources, id: \.root) { source in
                row(source)
            }
        }
        .task(id: generation) { await measure() }
        .confirmationDialog(
            forgetTitle,
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { source in
            Button("Forget Survey", role: .destructive) {
                syncManager.forgetSourceSurvey(root: source.root)
                generation += 1
            }
        } message: { _ in
            Text("Its survey goes to the Trash, and To File goes back to deciding how alike its folders are to \(FilingSurveyInUse.possessive(primaryName)).")
        }
    }

    private var forgetTitle: String {
        let owner = forgetting.map { FilingSurveyInUse.possessive($0.name) } ?? "this source’s"
        return "Forget \(owner) survey?"
    }

    private func isPrimary(_ root: String) -> Bool {
        primaryRoot.map { FilingSurveyInUse.isAtOrInsideSurvey(root, $0) } ?? false
    }

    @ViewBuilder
    private func row(_ source: (name: String, root: String)) -> some View {
        let status = statuses[source.root]
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .scaledFont(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isPrimary(source.root) {
                        Text("Primary")
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(caption(source, status))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isPrimary(source.root), let status {
                controls(source, status)
            } else if !isPrimary(source.root) {
                InlineSpinner()
            }
        }
        .help(source.root)
    }

    private func caption(_ source: (name: String, root: String), _ status: FilingSurveyInUse?) -> String {
        if isPrimary(source.root) {
            let folders = syncManager.filingFolderProfile?.folders.count ?? 0
            let date = syncManager.filingSurveyedAt.map { " · surveyed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            return "\(folders.formatted()) folders\(date)"
        }
        guard let status else { return "Measuring…" }
        let primary = FilingSurveyInUse.possessive(primaryName)
        switch status.kind {
        case .primary:
            return "Uses \(primary) survey"
        case .borrowed where status.total == 0:
            return "Empty · uses \(primary) survey until it holds folders"
        case .borrowed:
            return "Uses \(primary) survey · \(status.matchPercent) of folders match" + (status.chosen ? " · your choice" : "")
        case .own:
            let date = status.ownLearnedAt.map { " \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            return "Its own survey · \((status.ownFolderCount ?? 0).formatted()) folders learned\(date)"
        case .byName:
            return "No survey · \(status.matchPercent) of folders match \(primary) · placed by name"
        }
    }

    @ViewBuilder
    private func controls(_ source: (name: String, root: String), _ status: FilingSurveyInUse) -> some View {
        let learning = syncManager.learningSourceSurveyRoot.map { SourceSurveyStore.sameFolder($0, source.root) } ?? false
        HStack(spacing: 8) {
            if learning {
                InlineSpinner()
            } else if status.ownProfileId != nil {
                Picker("Survey for \(source.name)", selection: Binding(
                    get: { status.kind == .own ? SourceSurveyChoice.own : .primary },
                    set: { choice in
                        syncManager.setSourceSurveyChoice(root: source.root, choice)
                        generation += 1
                    })) {
                    Text("\(FilingSurveyInUse.possessive(primaryName)) Survey").tag(SourceSurveyChoice.primary)
                    Text("Its Own Survey").tag(SourceSurveyChoice.own)
                }
                .labelsHidden()
                .fixedSize()
                Button("Forget…") { forgetting = source }
                    .help("Move this source’s own survey to the Trash.")
            } else {
                Button("Learn Its Folders") {
                    Task {
                        _ = await syncManager.learnSourceSurvey(root: source.root)
                        generation += 1
                    }
                }
                .disabled(syncManager.learningSourceSurveyRoot != nil)
                .help("Reads folder names and how the files in them are named. Nothing downloads.")
            }
        }
    }

    private func measure() async {
        for source in sources where !isPrimary(source.root) {
            let status = await syncManager.sourceSurveyStatus(root: source.root)
            if Task.isCancelled { return }
            statuses[source.root] = status
        }
    }
}
