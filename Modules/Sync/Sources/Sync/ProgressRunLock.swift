import Foundation

extension Progress {
    private static let runLockReasonKey = ProgressUserInfoKey("SyncCloudRunLockReason")
    private static let runTitleKey = ProgressUserInfoKey("SyncCloudRunTitle")
    private static let firstPublishedKey = ProgressUserInfoKey("SyncCloudFirstPublished")

    /// The run's own name ("Copying 3 items"), kept when ``markFinishing(_:)`` replaces its
    /// description, so its notification and Activity row can still name it once it ends.
    public var runTitle: String? {
        userInfo[Self.runTitleKey] as? String ?? localizedDescription
    }

    /// When this run was first published on `activeProgress`. A run published again (a merge
    /// handing back its progress after its trash, `deleteItems(resumingProgress:)`) keeps its
    /// start, so it is not taken for the newest run in the capsule, and its log span covers the
    /// whole run.
    func firstPublished(now: Date = Date()) -> Date {
        if let date = userInfo[Self.firstPublishedKey] as? Date { return date }
        setUserInfoObject(now, forKey: Self.firstPublishedKey)
        return now
    }

    /// Why the window's writes are greyed while this run is `activeProgress` ("Wait for the copy to
    /// finish"), shown in the tooltip of every action it disables. Set by whoever publishes the
    /// run, since only it knows what kind of run it is; `nil` reads as ``genericRunLockReason``.
    public var runLockReason: String? {
        get { userInfo[Self.runLockReasonKey] as? String }
        set { setUserInfoObject(newValue, forKey: Self.runLockReasonKey) }
    }

    /// The reason for a run that named none: the words the managers' own refusals use.
    public static let genericRunLockReason = "Wait for the current operation to finish"

    /// "Wait for the copy to finish": the sentence every run's reason is built from.
    public static func runLockReason(waitingFor run: String) -> String {
        "Wait for \(run) to finish"
    }

    /// The run's work is done and only its undo is still being armed (the identity walk a copy,
    /// move or merge awaits). Nothing is left to stop, so the capsule drops Stop and ⌘. and says
    /// so. The run lock stays up until the run returns, because ⌘Z must not reach an undo whose
    /// identities are still being read. `run` names it ("the copy") since other runs can show
    /// beside it.
    public func markFinishing(_ run: String) {
        if userInfo[Self.runTitleKey] == nil, let title = localizedDescription {
            setUserInfoObject(title, forKey: Self.runTitleKey)
        }
        isCancellable = false
        localizedDescription = Self.finishingTitle(run)
    }

    /// "Finishing the copy…": what a run reads while it arms its undo.
    public static func finishingTitle(_ run: String) -> String {
        "Finishing \(run)…"
    }
}
