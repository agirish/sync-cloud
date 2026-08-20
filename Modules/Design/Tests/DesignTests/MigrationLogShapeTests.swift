import Testing
import Design
import Foundation

@Suite struct MigrationLogShapeTests {
    /// The launch line names the string that was ON DISK, not the size's current label.
    ///
    /// Built from the same pieces `SyncCloudApp.init` formats, because the line itself is inside
    /// an `if let` in `MacApp` that no package test can execute — what can be checked is that the
    /// values it interpolates are the honest ones.
    @Test func theMigrationReportsWhatWasOnDisk() {
        let suite = "MigrationLogShapeTests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("extraLarge", forKey: FontSize.defaultsKey)
        let migrated = FontSize.migrateLegacyValue(in: defaults)

        let line = "Text size migrated: \"\(migrated?.raw ?? "")\" → \(migrated?.size.percent ?? 0)%"
        #expect(line == "Text size migrated: \"extraLarge\" → 135%", "\(line)")
        // The failure it replaced, spelled out so it cannot come back by accident.
        #expect(!line.contains("Largest"),
                "the line names the size's current label rather than the value that was on disk")
    }
}
