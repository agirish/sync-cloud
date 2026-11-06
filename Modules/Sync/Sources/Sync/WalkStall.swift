import Foundation

/// Makes a directory walk arbitrarily slow, on demand, so the pane's slow-provider behaviour can be
/// reproduced without waiting for a cloud provider to actually be cold.
///
/// For the Columns display-cycle crash (`docs/columns-layout-loop.md`), whose crashes came while a
/// provider was cold and its deep walk took tens of seconds, so the next provider switch landed
/// on a load still in flight. Warm walks take under a second and never overlap, so hammering the
/// app hides the condition. This knob turns "wait for iCloud to go cold" into a parameter.
///
/// Off unless asked for, and free when off: read from `UserDefaults` once into a `static let`, so a
/// disabled stall costs one integer load per directory on a path that runs tens of thousands of
/// times per walk. An unset key reads 0, the disabled state, so no separate flag can disagree.
///
/// ```sh
/// defaults write com.abhishekgirish.SyncCloud debugWalkStallMillisecondsPerDirectory -int 15
/// ```
///
/// 15 ms over the ~2,600 directories of a real provider root is roughly a 40-second walk, the top
/// of the range real cold walks take.
///
/// Two modes: by default the stall suspends (`Task.sleep`), leaving the walk's concurrency as it
/// is; `blocks` makes it block a thread, as a cold provider does inside `getattrlistbulk`.
///
/// Neither mode reproduces the layout runaway: with walks stretched and switches landing mid-walk,
/// the tree still publishes in tens of milliseconds. So the slow walk is a correlate of the crash,
/// not its cause; this stays so the check can be re-run in seconds.
public enum WalkStall {
    /// `defaults write com.abhishekgirish.SyncCloud debugWalkStallMillisecondsPerDirectory -int <ms>`
    public static let defaultsKey = "debugWalkStallMillisecondsPerDirectory"

    /// Milliseconds to stall per directory listing; 0 (the default) or a negative value disables
    /// it. Read once; see the type's note.
    public static let millisecondsPerDirectory: Int = max(0, UserDefaults.standard.integer(forKey: defaultsKey))

    /// Whether a stall is armed. Public so the log can say so: a stall left on by accident would
    /// look exactly like the provider slowness it imitates.
    public static var isArmed: Bool { millisecondsPerDirectory > 0 }

    /// Whether the stall should BLOCK its thread rather than suspend.
    ///
    /// ```sh
    /// defaults write com.abhishekgirish.SyncCloud debugWalkStallBlocks -bool YES
    /// ```
    ///
    /// The suspending stall reproduces overlap (the next switch lands mid-walk) but not what a cold
    /// provider does: block a thread inside `getattrlistbulk`. The walk fans out across a bounded
    /// task group on the cooperative pool, so real blocking starves the pool.
    ///
    /// **Off by default because it is dangerous**: block enough directories and the cooperative
    /// pool has no thread left to make progress.
    public static let blocks: Bool = UserDefaults.standard.bool(forKey: "debugWalkStallBlocks")

    /// Stalls one directory listing. A no-op, and in practice not a suspension point, when disabled.
    public static func perDirectory() async {
        guard isArmed else { return }
        if blocks {
            // `usleep`, since the compiler bars `Thread.sleep` from async contexts. Blocking here
            // is the hazard on purpose: it is what a cold provider's `getattrlistbulk` does.
            usleep(UInt32(millisecondsPerDirectory) * 1000)
        } else {
            try? await Task.sleep(for: .milliseconds(millisecondsPerDirectory))
        }
    }
}
