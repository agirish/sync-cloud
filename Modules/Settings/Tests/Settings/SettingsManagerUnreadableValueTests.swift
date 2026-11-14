import Testing
import Foundation
@testable import Settings
import Sync

/// The five sibling properties of `folderSources` read tolerantly and write unconditionally, so an
/// unreadable stored value would be overwritten by the user's next edit (five disabled providers
/// become one; a newer build's sort choice vanishes after a downgrade). `readSetting` preserves it
/// under `<key>.unreadable` and reports it before any write can destroy it.
@Suite struct SettingsManagerUnreadableValueTests {

    /// disabledProviderIds is the sharpest case: a foreign-typed value silently re-enables every
    /// provider the user turned off, and the next toggle persists that.
    @MainActor
    @Test func aForeignTypedDisabledProviderListIsPreservedNotDestroyed() {
        let test = TestDefaults()
        test.defaults.set(Data([0x00, 0x01]), forKey: "disabledProviderIds")

        let settings = test.manager()
        #expect(settings.disabledProviderIds.isEmpty, "the tolerant fallback itself is right")
        #expect(test.defaults.object(forKey: "disabledProviderIds.unreadable") != nil,
                "an unreadable disabled-provider list must be preserved under the sibling key before the next toggle overwrites it")
    }

    @MainActor
    @Test func aForeignTypedIgnorePatternListIsPreservedNotDestroyed() {
        let test = TestDefaults()
        test.defaults.set("*.tmp,*.bak", forKey: "ignorePatterns")   // a String where [String] belongs

        let settings = test.manager()
        #expect(settings.ignorePatterns.isEmpty)
        #expect(test.defaults.object(forKey: "ignorePatterns.unreadable") != nil,
                "an unreadable ignore-pattern list must be preserved before the next edit destroys it")
    }

    /// The scalar shape: an unrecognized raw value (a newer build's case, after a downgrade) falls
    /// back safely, but the user's next touch would silently drop the newer build's choice.
    /// Preserving the raw original under the sibling key keeps the round trip.
    @MainActor
    @Test func anUnrecognizedSortOptionIsPreservedNotDestroyed() {
        let test = TestDefaults()
        test.defaults.set("fromTheFuture", forKey: "defaultSortOption")

        let settings = test.manager()
        #expect(settings.defaultSortOption == .name, "the tolerant fallback itself is right")
        #expect(test.defaults.object(forKey: "defaultSortOption.unreadable") != nil,
                "a newer build's sort choice must survive a downgrade edit")
    }

    @MainActor
    @Test func anUnrecognizedConflictPolicyIsPreservedNotDestroyed() {
        let test = TestDefaults()
        test.defaults.set("fromTheFuture", forKey: ConflictPolicy.defaultsKey)

        let settings = test.manager()
        #expect(settings.conflictPolicy == .ask)
        #expect(test.defaults.object(forKey: ConflictPolicy.defaultsKey + ".unreadable") != nil)
    }

    @MainActor
    @Test func anUnrecognizedFolderNameRuleIsPreservedNotDestroyed() {
        let test = TestDefaults()
        test.defaults.set("fromTheFuture", forKey: "folderNameRuleProvider")

        let settings = test.manager()
        #expect(settings.folderNameRule == .oneDrive)
        #expect(test.defaults.object(forKey: "folderNameRuleProvider.unreadable") != nil)
    }

    // MARK: The seam's own edges, driven directly like `readFolderSources`' suite drives it

    /// A readable value decodes and leaves no backup: ordinary data never reaches the salvage.
    @MainActor
    @Test func aReadableValueStillDecodesWithNoBackup() {
        let test = TestDefaults()
        test.defaults.set(["*.tmp"], forKey: "ignorePatterns")

        let value = SettingsManager.readSetting("ignorePatterns", from: test.defaults,
                                                describing: "ignore-pattern list") {
            $0.stringArray(forKey: "ignorePatterns")
        }
        #expect(value == ["*.tmp"])
        #expect(test.defaults.object(forKey: "ignorePatterns.unreadable") == nil)
    }

    /// A first launch has no value and must not write a backup of nothing.
    @MainActor
    @Test func anAbsentValueLeavesNoBackup() {
        let test = TestDefaults()
        let value = SettingsManager.readSetting("defaultSortOption", from: test.defaults,
                                                describing: "default sort order") {
            $0.string(forKey: "defaultSortOption").flatMap(SortOption.init(rawValue:))
        }
        #expect(value == nil)
        #expect(test.defaults.object(forKey: "defaultSortOption.unreadable") == nil,
                "a fresh install wrote a backup of nothing")
    }

    /// The step that would destroy the original is the next write, not the read. With the value
    /// preserved, the didSet's overwrite of the main key loses nothing.
    @MainActor
    @Test func theDidSetOverwriteNoLongerDestroysTheOriginal() {
        let test = TestDefaults()
        test.defaults.set("fromTheFuture", forKey: "defaultSortOption")

        let settings = test.manager()
        settings.defaultSortOption = .kind   // the first post-downgrade edit — fires the didSet

        #expect(test.defaults.string(forKey: "defaultSortOption") == SortOption.kind.rawValue)
        #expect(test.defaults.string(forKey: "defaultSortOption.unreadable") == "fromTheFuture",
                "the newer build's choice must still be under the sibling key after the edit")
    }

    /// A re-launch on a still-unreadable value must not rewrite the same payload every time.
    @MainActor
    @Test func rereadingDoesNotRewriteTheBackup() {
        let test = TestDefaults()
        test.defaults.set(Data([0x00]), forKey: "disabledProviderIds")

        func readOnce() -> Set<String>? {
            SettingsManager.readSetting("disabledProviderIds", from: test.defaults,
                                        describing: "disabled-provider list") {
                $0.stringArray(forKey: "disabledProviderIds").map(Set.init)
            }
        }
        _ = readOnce()
        let firstBackup = test.defaults.data(forKey: "disabledProviderIds.unreadable")
        #expect(firstBackup != nil)
        _ = readOnce()
        #expect(test.defaults.data(forKey: "disabledProviderIds.unreadable") == firstBackup)
    }
}
