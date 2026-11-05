import Testing
import Design
import Foundation

@Suite struct MigrationLogShapeTests {
    /// The launch line names the string that was on disk, not the size's current label.
    ///
    /// Built from the same pieces `SyncCloudApp.init` formats, because the line itself sits in an
    /// `if let` in `MacApp` that no package test can run; this checks the values it interpolates.
    @Test func theMigrationReportsWhatWasOnDisk() {
        let defaults = ScratchDefaults("MigrationLogShapeTests")

        defaults.set("extraLarge", forKey: FontSize.defaultsKey)
        let migrated = FontSize.migrateLegacyValue(in: defaults)

        let line = "Text size migrated: \"\(migrated?.raw ?? "")\" → \(migrated?.size.percent ?? 0)%"
        #expect(line == "Text size migrated: \"extraLarge\" → 135%", "\(line)")
        // The current label must not stand in for the stored value.
        #expect(!line.contains("Largest"),
                "the line names the size's current label rather than the value that was on disk")
    }
}
