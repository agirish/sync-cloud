import Testing
import Foundation
@testable import Settings
import Sync

/// The sibling properties of the settings store share `FileSyncManager.readPersistedStore`'s
/// read-tolerantly-then-write-unconditionally shape without its salvage: a stored value this build
/// cannot read is treated as the default, and the user's next edit of that setting writes the
/// default-derived value over the original — destroying it with nothing in the log to explain why
/// (five disabled providers become one; a newer build's sort choice vanishes after a downgrade
/// edit).
///
/// `SettingsManager.readSetting` is the fix these pin: an unreadable stored value is preserved
/// under `<key>.unreadable` and reported, BEFORE any write can destroy it. The tolerant in-memory
/// fallback itself is correct and is asserted here too — the defect was only that the original was
/// not kept.
@Suite struct SettingsManagerUnreadableValueTests {

    @MainActor
    private func makeManager(_ test: TestDefaults) -> SettingsManager {
        SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })
    }

    /// disabledProviderIds is the sharpest of the siblings: a foreign-typed value silently
    /// re-enables every provider the user turned off, and the next toggle persists that.
    @MainActor
    @Test func aForeignTypedDisabledProviderListIsPreservedNotDestroyed() {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set(Data([0x00, 0x01]), forKey: "disabledProviderIds")

        let settings = makeManager(test)
        #expect(settings.disabledProviderIds.isEmpty, "the tolerant fallback itself is right")
        #expect(test.defaults.object(forKey: "disabledProviderIds.unreadable") != nil,
                "an unreadable disabled-provider list must be preserved under the sibling key before the next toggle overwrites it")
    }

    @MainActor
    @Test func aForeignTypedIgnorePatternListIsPreservedNotDestroyed() {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set("*.tmp,*.bak", forKey: "ignorePatterns")   // a String where [String] belongs

        let settings = makeManager(test)
        #expect(settings.ignorePatterns.isEmpty)
        #expect(test.defaults.object(forKey: "ignorePatterns.unreadable") != nil,
                "an unreadable ignore-pattern list must be preserved before the next edit destroys it")
    }

    /// The scalar shape: an unrecognized raw value (a newer build's case, after a downgrade) falls
    /// back safely, but the next time the user touches the setting the newer build's choice is
    /// silently gone. Preserving the raw original under the sibling key keeps the round trip.
    @MainActor
    @Test func anUnrecognizedSortOptionIsPreservedNotDestroyed() {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set("fromTheFuture", forKey: "defaultSortOption")

        let settings = makeManager(test)
        #expect(settings.defaultSortOption == .name, "the tolerant fallback itself is right")
        #expect(test.defaults.object(forKey: "defaultSortOption.unreadable") != nil,
                "a newer build's sort choice must survive a downgrade edit")
    }

    @MainActor
    @Test func anUnrecognizedConflictPolicyIsPreservedNotDestroyed() {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set("fromTheFuture", forKey: ConflictPolicy.defaultsKey)

        let settings = makeManager(test)
        #expect(settings.conflictPolicy == .ask)
        #expect(test.defaults.object(forKey: ConflictPolicy.defaultsKey + ".unreadable") != nil)
    }

    // MARK: The seam's own edges, driven directly like `readFolderSources`' suite drives it

    /// A readable value decodes and leaves no backup — the salvage must not be reached for
    /// ordinary data.
    @MainActor
    @Test func aReadableValueStillDecodesWithNoBackup() {
        let test = TestDefaults()
        defer { test.wipe() }
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
        defer { test.wipe() }
        let value = SettingsManager.readSetting("defaultSortOption", from: test.defaults,
                                                describing: "default sort order") {
            $0.string(forKey: "defaultSortOption").flatMap(SortOption.init(rawValue:))
        }
        #expect(value == nil)
        #expect(test.defaults.object(forKey: "defaultSortOption.unreadable") == nil,
                "a fresh install wrote a backup of nothing")
    }

    /// The step that actually destroys the original: not the read, the NEXT write. With the value
    /// preserved, the didSet's overwrite of the main key is no longer the end of it.
    @MainActor
    @Test func theDidSetOverwriteNoLongerDestroysTheOriginal() {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set("fromTheFuture", forKey: "defaultSortOption")

        let settings = makeManager(test)
        settings.defaultSortOption = .kind   // the first post-downgrade edit — fires the didSet

        #expect(test.defaults.string(forKey: "defaultSortOption") == SortOption.kind.rawValue)
        #expect(test.defaults.string(forKey: "defaultSortOption.unreadable") == "fromTheFuture",
                "the newer build's choice must still be under the sibling key after the edit")
    }

    /// A re-launch on a still-unreadable value must not rewrite the same payload every time.
    @MainActor
    @Test func rereadingDoesNotRewriteTheBackup() {
        let test = TestDefaults()
        defer { test.wipe() }
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
