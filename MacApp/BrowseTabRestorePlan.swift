import Sync

/// The launch-restore DECISION, separated from the `View`-extension glue that executes it.
///
/// `restoreBrowseTabs` lives on a `View` extension nothing can instantiate, so for as long as the
/// decision lived inline, every one of its branches was pinned by source scans alone — a refactor
/// that kept the spellings while changing the behavior passed the whole repo. `PaneTabsStore.restore`
/// already owns dropping and re-rooting; what remained unowned was the *account* of it: which lines
/// are said, in what order, what is installed, and whether the pane must adopt the active tab's
/// provider before the tab is applied. That account is this value, computed purely so a test can
/// execute every branch — the ordering rules the old scans asserted as text (a claim of a restore
/// must not precede the guard that can abandon it) are now the order of `Plan.lines`.
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

        // **What the restore threw away, before what it kept.** `PaneTabsStore.restore` drops an
        // entry whose source this pane cannot be pointed at; the commonest way is the user
        // switching a source OFF in Settings — reversible there, not here. Dropping is right
        // (a tab that cannot be opened is not a place), doing it in silence is not: the strip is
        // rewritten by the first save, so those tabs are gone for good. He audits this log.
        let dropped = storedCount - (outcome?.list.count ?? 0)
        if dropped > 0 {
            plan.lines.append(Line(level: .warning, message:
                "Dropped \(dropped) stored \(side) browse tab\(dropped == 1 ? "" : "s"): "
                + "their source is gone or switched off"))
        }

        guard let restored = outcome?.list, !restored.isSeedState else {
            // **The abandoned restore lost a folder too, and this is the only branch that can say
            // so truthfully.** A one-entry strip whose only folder is gone re-roots to `""` —
            // exactly the seed state — so nothing is installed, and the "at its source root" line
            // below would claim a tab came back that did not. At most one folder can reach this
            // branch, because the seed state is a one-tab strip.
            if let lost = (outcome?.lostFolders ?? []).first {
                plan.lines.append(Line(level: .warning, message:
                    "Did not restore the \(side) browse tab “\(lost)”: its "
                    + "folder no longer exists, and one tab at a source root is the state a fresh "
                    + "launch already seeds"))
            }
            return plan
        }

        // **What came back at the wrong place, which the dropped count cannot see.** A tab whose
        // FOLDER is gone is re-rooted rather than dropped, and the restored strip then looks
        // exactly like one the user left at the root — the first save writes the root over the
        // stored path for good. The stored path is the last place that folder is named at all, so
        // it is named here, per side. He audits this log.
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
