import Foundation

/// The first launch of a build where the preview lives in the Info inspector (TE318, his call
/// 2026-11-04): Info opens for anyone who had the in-pane preview on, and the preview is folded
/// away for anyone who had it off.
///
/// Without it every upgrade lost the preview without a word. It defaulted to on in every pane, so
/// selecting a file showed one; Info, which now holds it, defaults to closed — so the same click
/// showed nothing anywhere until the user found ⌘I. And someone who had turned the preview off but
/// kept Info open for its details found a preview taking most of the panel.
///
/// **Once, stamped.** After the first launch Info stays as the user leaves it; a later close is never
/// undone. A new install has no preview setting stored, which reads as the default — on — so it
/// starts with Info open too.
enum InfoPreviewMigration {
    /// The in-pane preview's two settings, no longer read by anything else: Compare and the rail's,
    /// and Browse's own. Spelled out because the constants that named them went with the preview.
    static let comparePreviewKey = "paneColumnShowsPreview"
    static let browsePreviewKey = "paneColumnShowsPreviewBrowse"
    /// The stamp that says this has run.
    static let doneKey = "infoPreviewMigrationDone"
    /// What the app reads: whether Info is open, and the preview's share of it.
    static let inspectorShownKey = "showCompareInspector"
    static let previewFractionKey = "infoInspectorPreviewFraction"

    enum Outcome: Equatable {
        /// The preview was on somewhere: Info is open.
        case openedInfo
        /// The preview was off everywhere: Info is as it was, with the preview folded away.
        case foldedPreview
    }

    /// Runs the step if it has not run, and says what it did.
    @discardableResult
    static func run(in defaults: UserDefaults) -> Outcome? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        defaults.set(true, forKey: doneKey)
        // Absent is the default, and the default was on.
        let compare = defaults.object(forKey: comparePreviewKey) as? Bool ?? true
        let browse = defaults.object(forKey: browsePreviewKey) as? Bool ?? true
        if compare || browse {
            defaults.set(true, forKey: inspectorShownKey)
            return .openedInfo
        }
        defaults.set(0.0, forKey: previewFractionKey)
        return .foldedPreview
    }
}
