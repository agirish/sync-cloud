import Sync

/// The launch-restore decision, kept apart from the `View`-extension glue that executes it.
///
/// `restoreBrowseTabs` lives on a `View` extension nothing can instantiate, so a test can't run it.
/// `PaneTabsStore.restore` owns dropping and re-rooting; this owns the account of it: which lines
/// are logged, in what order, what is installed, and whether the pane must adopt the active tab's
/// provider first. It is computed purely so a test can execute every branch, including the rule
/// that no claim of a restore precedes the guard that can abandon it.
enum BrowseTabRestorePlan {

    struct Line: Equatable {
        enum Level: Equatable { case warning, info }
        let level: Level
        let message: String
    }

    struct Plan {
        /// Log lines in emission order. The order is load-bearing: the re-rooted claims and the
        /// restored count must never be emitted for an abandoned restore, and the abandoned line
        /// replaces them — see the branch notes in `plan`.
        var lines: [Line] = []
        /// The strip to install, or nil when the restore is abandoned: nothing stored, or a strip
        /// that reduced to the seed state a fresh launch already opens in.
        var install: PaneTabList?
        /// The provider the pane must adopt (with `adoptLog` as its audit line) before the active
        /// tab is applied — set only when the active tab names a source the pane is not on and CAN
        /// be pointed at. The write itself stays in the host: it must go through
        /// `adoptProviderForTab`'s suppression counter, never a bare id assignment.
        var adoptProviderId: String?
        var adoptLog: String?
    }

    static func plan(storedCount: Int,
                     outcome: PaneTabsStore.Restored?,
                     isLeft: Bool,
                     currentProviderId: String,
                     canShowSource: (String) -> Bool) -> Plan {
        var plan = Plan()
        let side = PaneSideChoice.name(isLeft)

        // What the restore threw away, before what it kept. `PaneTabsStore.restore` drops an
        // entry whose source this pane can't show, usually one switched off in Settings. Dropping
        // is right, but never silently: the first save rewrites the strip, so those tabs are gone
        // for good.
        let dropped = storedCount - (outcome?.list.count ?? 0)
        if dropped > 0 {
            plan.lines.append(Line(level: .warning, message:
                "Dropped \(dropped) stored \(side) browse tab\(dropped == 1 ? "" : "s"): "
                + "their source is gone or switched off"))
        }

        guard let restored = outcome?.list, !restored.isSeedState else {
            // An abandoned restore can still have lost a folder, and only this branch can say so
            // truthfully: a one-entry strip whose folder is gone re-roots to `""`, the seed state,
            // so nothing is installed and the "at its source root" line below would be false. At
            // most one folder reaches here, since the seed state is a one-tab strip.
            if let lost = (outcome?.lostFolders ?? []).first {
                plan.lines.append(Line(level: .warning, message:
                    "Did not restore the \(side) browse tab “\(lost)”: its "
                    + "folder no longer exists, and one tab at a source root is the state a fresh "
                    + "launch already seeds"))
            }
            return plan
        }

        // What came back at the wrong place, which the dropped count can't see. A tab whose
        // folder is gone is re-rooted, not dropped, and the first save writes the root over the
        // stored path for good. The stored path is the last place that folder is named, so it is
        // logged here, per side.
        for lost in outcome?.lostFolders ?? [] {
            plan.lines.append(Line(level: .warning, message:
                "Restored the \(side) browse tab “\(lost)” at its source root: "
                + "the folder no longer exists"))
        }
        plan.lines.append(Line(level: .info, message:
            "Restored \(restored.count) \(side) browse tab\(restored.count == 1 ? "" : "s")"))
        plan.install = restored

        // The restored ACTIVE tab is the pane's position, so its provider must be adopted like any
        // other switch — but only onto a source the pane can show, and only when it is a change.
        let active = restored.active
        if active.providerId != currentProviderId, canShowSource(active.providerId) {
            plan.adoptProviderId = active.providerId
            plan.adoptLog = "Restored \(side) browse tab moved the pane to \(active.providerId)"
        }
        return plan
    }
}
