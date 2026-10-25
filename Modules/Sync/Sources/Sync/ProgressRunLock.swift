import Foundation

extension Progress {
    private static let runLockReasonKey = ProgressUserInfoKey("SyncCloudRunLockReason")

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
}
