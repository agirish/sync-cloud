import Design
import SwiftUI
import Sync

/// Settings ▸ Organize ▸ Folder surveys: every cloud source and the survey that places its files.
/// The same choices as To File's survey menu, for sources To File hasn't looked at yet, and the one
/// place a source's own survey is forgotten.
struct FolderSurveysSection: View {
    @ObservedObject var syncManager: FileSyncManager
    /// Cloud sources by name and the folder To File files into for each (its landing folder).
    let sources: [(name: String, root: String)]

    /// What each source uses, measured on appear and after every change here.
    @State private var statuses: [String: FilingSurveyInUse] = [:]
    @State private var forgetting: (name: String, root: String)?
    @State private var generation = 0
    /// The source whose documents are being counted for Read Documents' sheet.
    @State private var counting: String?
    @State private var pending: PendingReading?

    /// A counted reading waiting on its sheet.
    private struct PendingReading: Identifiable {
        let id = UUID()
        let plan: FileSyncManager.DocumentSurveyPlan
        let facts: SourceDocumentsFacts
    }

    private var primaryRoot: String? { syncManager.filingFolderProfile?.recordedFolderPath }

    private var primaryName: String {
        primaryRoot.flatMap { FilingSurveyInUse.sourceName(for: $0, sources: sources) } ?? "iCloud"
    }

    var body: some View {
        SettingsSection(
            "Folder surveys",
            caption: "What To File knows about each source’s folders. Learning reads names only; nothing downloads."
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
            Text("Its survey goes to the Trash, with any documents it read, and To File goes back to deciding how alike its folders are to \(FilingSurveyInUse.possessive(primaryName)).")
        }
        .sheet(item: $pending) { reading in
            SourceDocumentsSheet(facts: reading.facts, onCancel: { pending = nil }, onRead: {
                pending = nil
                Task {
                    await syncManager.readSourceDocuments(plan: reading.plan)
                    generation += 1
                }
            })
            .presentedNativeControlAccent()
        }
    }

    /// Counts `source`'s documents and opens the sheet, or says on the banner why it cannot.
    private func count(_ source: (name: String, root: String)) {
        counting = source.root
        Task {
            defer { counting = nil }
            switch await syncManager.planSourceDocumentSurvey(sourceRoot: source.root) {
            case .failure(let refusal):
                syncManager.banner = .warning(refusal.sentence, log: .warn)
            case .success(let plan) where plan.total == 0:
                syncManager.banner = .success("Nothing to read — no document in \(source.name) is in a format this app can open.")
            case .success(let plan):
                pending = PendingReading(plan: plan, facts: SourceDocumentsFacts(
                    sourceName: source.name, documents: plan.total, toDownload: plan.toDownload,
                    unreadableTypes: plan.skippedUnreadableTypes,
                    alreadyRead: syncManager.resumableSourceDocumentSurvey(sourceRoot: source.root)?.done))
            }
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
            return "Its own survey · \((status.ownFolderCount ?? 0).formatted()) folders learned\(date) · "
                + Self.readingClause(status, reading: syncManager.isReadingDocuments(ofSource: source.root)
                                        ? syncManager.documentSurveyProgress : nil)
        case .byName:
            return "No survey · \(status.matchPercent) of folders match \(primary) · placed by name"
        }
    }

    /// "12,610 documents read 1 Nov", "documents not read", or the reading under way.
    static func readingClause(_ status: FilingSurveyInUse, reading progress: DocumentSurveyProgress?) -> String {
        if let progress {
            return "reading documents, \(progress.completed.formatted()) of \(progress.total.formatted())"
                + (progress.isPaused ? ", paused" : "")
        }
        guard let read = status.ownDocumentsRead, let at = status.ownDocumentsReadAt else { return "documents not read" }
        return "\(read.formatted()) document\(read == 1 ? "" : "s") read \(at.formatted(date: .abbreviated, time: .omitted))"
    }

    @ViewBuilder
    private func controls(_ source: (name: String, root: String), _ status: FilingSurveyInUse) -> some View {
        let learning = syncManager.learningSourceSurveyRoot.map { SourceSurveyStore.sameFolder($0, source.root) } ?? false
        let reading = syncManager.isReadingDocuments(ofSource: source.root)
        HStack(spacing: 8) {
            if learning || counting == source.root {
                InlineSpinner()
            } else if reading {
                InlineSpinner()
                Button("Stop") { Task { await syncManager.stopDocumentSurvey() } }
                    .help("Stops after the document being read. What was read is kept, and reading again carries on from there.")
            } else if status.ownProfileId != nil {
                if status.ownDocumentsReadAt == nil {
                    Button("Read Documents…") { count(source) }
                        .disabled(counting != nil || syncManager.filingSurveyLifecycle.isRunning)
                        .help("Reads page 1 of each document so To File and Ask Claude know what each folder holds. Counts them and asks before it starts.")
                }
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
