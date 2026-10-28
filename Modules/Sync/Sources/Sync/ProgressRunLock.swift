import Foundation

extension Progress {
    private static let runLockReasonKey = ProgressUserInfoKey("SyncCloudRunLockReason")
    private static let runTitleKey = ProgressUserInfoKey("SyncCloudRunTitle")
    private static let firstPublishedKey = ProgressUserInfoKey("SyncCloudFirstPublished")

    /// The run's own name — "Copying 3 items" — kept when ``markFinishing()`` puts "Finishing…" in
    /// its description, for what names the run once it ends: its notification and Activity's row.
    public var runTitle: String? {
        userInfo[Self.runTitleKey] as? String ?? localizedDescription
    }

    /// When this run was FIRST published on `activeProgress`. A run published again — a merge
    /// handed back its progress after its trash (`deleteItems(resumingProgress:)`) — keeps its
    /// start, so it is not taken for the newest run in the capsule, nor its ending's log span cut
    /// to the minutes after the trash.
    func firstPublished(now: Date = Date()) -> Date {
        if let date = userInfo[Self.firstPublishedKey] as? Date { return date }
        setUserInfoObject(now, forKey: Self.firstPublishedKey)
        return now
    }

    /// **Why the window's writes are greyed while this run is `activeProgress`** — "Wait for the
    /// copy to finish" — said in the tooltip of every action it disables (decision BZ). Set by
    /// whoever publishes the run, since only it knows what kind of run it is; `nil` reads as the
    /// generic ``genericRunLockReason``.
    public var runLockReason: String? {
        get { userInfo[Self.runLockReasonKey] as? String }
        set { setUserInfoObject(newValue, forKey: Self.runLockReasonKey) }
    }

    /// The reason for a run that named none — the words the managers' own refusals already use.
    public static let genericRunLockReason = "Wait for the current operation to finish"

    /// "Wait for the copy to finish" — the sentence every run's reason is built from, so they read
    /// as one family.
    public static func runLockReason(waitingFor run: String) -> String {
        "Wait for \(run) to finish"
    }

    /// The run's work is done and only its undo is still being armed — the identity walk a
    /// copy, move or merge awaits before it reports done. Nothing is left that a Stop could stop,
    /// so the capsule drops its Stop and ⌘. and says so; the run lock stays up until the run
    /// returns, because ⌘Z must not reach an undo whose identities are still being read.
    public func markFinishing() {
        if userInfo[Self.runTitleKey] == nil, let title = localizedDescription {
            setUserInfoObject(title, forKey: Self.runTitleKey)
        }
        isCancellable = false
        localizedDescription = "Finishing…"
    }
}
