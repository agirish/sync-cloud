import Testing
import Foundation
@testable import SyncCloud

/// The first launch with the preview in the Info inspector (TE318): Info opens for anyone who had
/// the preview on, the preview folds away for anyone who had it off, and it happens once.
@Suite struct InfoPreviewMigrationTests {
    typealias Step = InfoPreviewMigration

    private func defaults(_ name: String) -> UserDefaults { ScratchDefaults("info-preview-\(name)") }

    /// A new install, and an upgrade that never touched the preview, stored nothing — the default,
    /// on — so both open Info.
    @Test func withNothingStoredInfoOpens() {
        let d = defaults("nothing")
        #expect(Step.run(in: d) == .openedInfo)
        #expect(d.bool(forKey: Step.inspectorShownKey))
        #expect(d.object(forKey: Step.previewFractionKey) == nil, "the split was touched for a preview that was on")
    }

    /// On in one workspace is on: Browse kept its preview while Compare's was off, and that user
    /// still selects files expecting one.
    @Test func thePreviewOnInEitherWorkspaceOpensInfo() {
        let d = defaults("either")
        d.set(false, forKey: Step.comparePreviewKey)
        d.set(true, forKey: Step.browsePreviewKey)
        d.set(false, forKey: Step.inspectorShownKey)
        #expect(Step.run(in: d) == .openedInfo)
        #expect(d.bool(forKey: Step.inspectorShownKey))
    }

    /// Off everywhere: Info is left as it was, and its preview starts folded away.
    @Test func thePreviewOffEverywhereFoldsItAndLeavesInfoAlone() {
        let d = defaults("off")
        d.set(false, forKey: Step.comparePreviewKey)
        d.set(false, forKey: Step.browsePreviewKey)
        d.set(true, forKey: Step.inspectorShownKey)
        #expect(Step.run(in: d) == .foldedPreview)
        #expect(d.double(forKey: Step.previewFractionKey) == 0)
        #expect(d.bool(forKey: Step.inspectorShownKey), "Info was closed on someone who had it open")

        let closed = defaults("off-closed")
        closed.set(false, forKey: Step.comparePreviewKey)
        closed.set(false, forKey: Step.browsePreviewKey)
        Step.run(in: closed)
        #expect(!closed.bool(forKey: Step.inspectorShownKey), "Info was opened for someone who had the preview off")
    }

    /// Once: a close after the first launch stays closed.
    @Test func itRunsOnce() {
        let d = defaults("once")
        #expect(Step.run(in: d) == .openedInfo)
        d.set(false, forKey: Step.inspectorShownKey)
        #expect(Step.run(in: d) == nil)
        #expect(!d.bool(forKey: Step.inspectorShownKey), "a second launch reopened Info")
    }
}
