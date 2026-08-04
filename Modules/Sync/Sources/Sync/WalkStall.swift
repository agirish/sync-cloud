import Foundation

/// Makes a directory walk arbitrarily slow, on demand, so the pane's slow-provider behaviour can be
/// reproduced without waiting for a cloud provider to actually be cold.
///
/// **Why this exists.** The Columns display-cycle crash (`docs/columns-layout-loop.md`) has never
/// had a deterministic repro, and the reason turned out to be a precondition nobody had identified:
/// every crash, and every 9-13 s `publish`, happened while a provider was cold and the deep walk was
/// taking **25-46 seconds**, so the next provider switch landed *while the previous load was still
/// in flight* — `resetNavigation()` drops both pane trees onto an in-flight load. Warm, the same
/// walk takes 0.4-0.8 s, loads never overlap, and 38 consecutive provider switches across three
/// configurations were all 12-22 ms with no crash.
///
/// That is why the crash rate collapsed from 5/5 to roughly one-in-eight over a single evening of
/// investigation: hammering the app kept everything warm and destroyed the very condition being
/// hunted. A knob that stalls the walk turns "wait for iCloud to go cold" into a parameter.
///
/// **Off unless asked for, and free when off.** The value is read from `UserDefaults` exactly once
/// into a `static let`, so a disabled stall costs one already-resolved integer load per directory
/// and no defaults lookup, on a path that runs tens of thousands of times per walk. `integer(forKey:)`
/// answers 0 for an unset key, which is the disabled state — there is no separate enable flag to get
/// out of step with the duration.
///
/// ```sh
/// defaults write com.abhishekgirish.SyncCloud debugWalkStallMillisecondsPerDirectory -int 15
/// ```
///
/// 15 ms against the ~2,600 directories under a real 38k-node provider root is roughly a 40-second
/// walk — the top of the range the real stalls produced.
///
/// **Two modes, because the first one was not enough.** By default the stall SUSPENDS
/// (`Task.sleep`), which leaves the walk's concurrency untouched and delivers the property the
/// overlap hypothesis needed. `blocks` switches it to a real thread block, imitating what a cold
/// provider does inside `getattrlistbulk`. See `blocks` for what each one did and did not
/// reproduce.
///
/// **What this has NOT reproduced.** Neither mode produces the layout runaway. Walks stretched to
/// 10-15 s, switches landing mid-walk 8 times out of 8, the cooperative pool starved by real
/// blocking — and the 38,461-node tree still publishes in 22-58 ms every time. The slow walk is
/// therefore a correlate of the crash, not its cause, and this type's value is now that it ruled
/// that out cheaply and can be re-armed in seconds.
///
/// **Costs nothing when off**, measured: walks with the stall disabled land at 482-553 ms against a
/// 0.4-0.8 s baseline taken before this existed.
public enum WalkStall {
    /// `defaults write com.abhishekgirish.SyncCloud debugWalkStallMillisecondsPerDirectory -int <ms>`
    public static let defaultsKey = "debugWalkStallMillisecondsPerDirectory"

    /// Milliseconds to stall per directory listing; 0 (the default, and any negative value) disables
    /// the stall entirely. Read once — see the type's note on why this is a `static let`.
    public static let millisecondsPerDirectory: Int = max(0, UserDefaults.standard.integer(forKey: defaultsKey))

    /// Whether a stall is armed at all. Public so a diagnostic session can be *shown* in the log
    /// rather than silently changing how long every walk takes — a stall left on by accident would
    /// otherwise look exactly like the provider slowness it imitates.
    public static var isArmed: Bool { millisecondsPerDirectory > 0 }

    /// Whether the stall should BLOCK its thread rather than suspend.
    ///
    /// ```sh
    /// defaults write com.abhishekgirish.SyncCloud debugWalkStallBlocks -bool YES
    /// ```
    ///
    /// The suspending stall reproduces "the walk is still running when the next switch arrives" —
    /// verified, 8 of 8 switches landing on `superseded during the deep walk` — and that turned out
    /// **not** to be enough: walks stretched to 10 s, allowed to run to completion, still published a
    /// 38,461-node tree in 22-34 ms with no runaway. So overlap alone is not the missing ingredient.
    ///
    /// What a suspending stall cannot imitate is the part a real cold provider actually does: block
    /// a thread inside `getattrlistbulk` (visible in the 2026-08-02 crash report's thread 10). The
    /// walk fans out across a bounded task group on the cooperative pool, so real blocking starves
    /// that pool — and starvation, not elapsed time, may be what the runaway needs.
    ///
    /// Off by default because it is the dangerous half: enough blocked directories and the
    /// cooperative pool has no thread left to make progress on.
    public static let blocks: Bool = UserDefaults.standard.bool(forKey: "debugWalkStallBlocks")

    /// Stalls one directory listing. A no-op — and not a suspension point in practice — when
    /// disabled, so the walk keeps its measured shape.
    public static func perDirectory() async {
        guard isArmed else { return }
        if blocks {
            // `usleep`, not `Thread.sleep`, which the compiler bars from async contexts —
            // rightly, since blocking here is exactly the hazard. That is the point: it is what a
            // real `getattrlistbulk` against a cold provider does to this thread.
            usleep(UInt32(millisecondsPerDirectory) * 1000)
        } else {
            try? await Task.sleep(for: .milliseconds(millisecondsPerDirectory))
        }
    }
}
