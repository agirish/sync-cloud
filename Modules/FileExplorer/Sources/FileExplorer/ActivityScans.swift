import Foundation
import Design
import Sync

/// The long scans with cards of their own (Run Room TE228).
public enum ActivityScan: Equatable, Sendable {
    /// Read documents — Organize's overview card, with Pause, Resume and Stop.
    case readDocuments
    /// The duplicate scan — the Duplicates lens.
    case duplicates
    /// Restructure's apply — the Restructure lens, whose plan sheet shows it.
    case restructure
}

extension DocumentSurveyCardState {
    /// The card's state while a survey is reading, paused or finishing — `nil` once it ends.
    public static func live(_ progress: DocumentSurveyProgress) -> DocumentSurveyCardState {
        switch progress.phase {
        case .reading:
            return .running(done: progress.completed, total: progress.total, folder: progress.currentFolder,
                            secondsRemaining: progress.estimatedSecondsRemaining, pause: nil)
        case .paused(let reason):
            return .running(done: progress.completed, total: progress.total, folder: progress.currentFolder,
                            secondsRemaining: progress.estimatedSecondsRemaining,
                            pause: .init(sentence: reason.sentence, resumesOnItsOwn: reason.resumesOnItsOwn))
        case .finishing:
            // Its own state, not a pause — see `ContentView.documentSurveyCardState`.
            return .finishing(done: progress.completed)
        }
    }
}

/// **The long scans as Activity's Running rows** (TE228, decision CO): Read documents, the duplicate
/// scan and Restructure's apply. They run for minutes to hours and keep their controls on their own
/// cards, so they are listed with a Show that goes there — and never bring up the capsule, which
/// would otherwise sit in the toolbar all evening. Read documents says when it is paused, by the
/// reader or by the Mac (R21).
public enum ActivityScanRows {
    @MainActor
    public static func rows(_ manager: FileSyncManager,
                            show: @escaping (ActivityScan) -> Void) -> [ProgressCapsuleListedRun] {
        var rows: [ProgressCapsuleListedRun] = []
        if let progress = manager.documentSurveyProgress {
            let state = DocumentSurveyCardState.live(progress)
            let detail: String?
            if case .paused(let reason) = progress.phase {
                detail = reason.sentence + (reason.resumesOnItsOwn ? " Resumes on its own." : "")
            } else {
                detail = progress.currentFolder
            }
            rows.append(ProgressCapsuleListedRun(
                id: "scan.readDocuments",
                run: ProgressCapsuleRun(title: DocumentSurveyCardText.title(for: state),
                                        completed: Int64(progress.completed), total: Int64(progress.total),
                                        detail: detail),
                symbol: "doc.text.magnifyingglass", startedAt: progress.startedAt,
                onCancel: nil, onShow: { show(.readDocuments) }))
        }
        if manager.isFindingDuplicates {
            let counted = manager.duplicateScanProgress
            rows.append(ProgressCapsuleListedRun(
                id: "scan.duplicates",
                run: ProgressCapsuleRun(title: "Finding duplicates",
                                        completed: Int64(counted?.completed ?? 0), total: Int64(counted?.total ?? 0),
                                        detail: manager.duplicateScanLifecycle.status),
                symbol: "square.on.square", startedAt: nil,
                onCancel: nil, onShow: { show(.duplicates) }))
        }
        if let apply = manager.restructureApplyProgress {
            let counting = apply.stage == .operations && apply.opsTotal > 0
            rows.append(ProgressCapsuleListedRun(
                id: "scan.restructure",
                run: ProgressCapsuleRun(title: "Applying the reorganization",
                                        completed: Int64(counting ? apply.opsDone : 0),
                                        total: Int64(counting ? apply.opsTotal : 0),
                                        detail: apply.line()),
                symbol: "folder.badge.gearshape", startedAt: nil,
                onCancel: nil, onShow: { show(.restructure) }))
        }
        return rows
    }
}
