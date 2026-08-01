import Testing
import AppKit
@testable import SyncCloud

@Suite struct TopPaneVisibilityTests {

    // MARK: Mode & pane count

    @Test func testModePerWorkspace() {
        // Compare compares two locations; every lens scans one.
        #expect(TopPaneVisibility.mode(for: .compare) == .compare)
        for workspace in Workspace.lensWorkspaces {
            #expect(TopPaneVisibility.mode(for: workspace) == .singleSource)
        }
    }

    @Test func testPaneCountPerWorkspace() {
        #expect(TopPaneVisibility.paneCount(for: .compare) == 2)
        for workspace in Workspace.lensWorkspaces {
            #expect(TopPaneVisibility.paneCount(for: workspace) == 1)
        }
    }

    // MARK: Defaults

    @Test func testNothingStartsHidden() {
        // The rule the flat bar is built on — the source browser is in the same place on every
        // workspace — is only true on first use if the rail actually starts up. This changes what
        // `Tidy` defaulted to (its rail started collapsed), deliberately: you could not reach a
        // lens without the lens tabs, and picking one there opened the rail, so the collapsed
        // default described a state almost nobody saw.
        for workspace in Workspace.allCases {
            #expect(!TopPaneVisibility.defaultPanesHidden(for: workspace))
            #expect(!TopPaneVisibility.panesHidden(for: workspace, override: nil))
        }
    }

    @Test func testOverrideWinsOnEveryWorkspace() {
        for workspace in Workspace.allCases {
            #expect(TopPaneVisibility.panesHidden(for: workspace, override: true))
            #expect(!TopPaneVisibility.panesHidden(for: workspace, override: false))
        }
    }

    // MARK: Override encoding (persistence format stores `hidden`, keyed by workspace raw value)

    @Test func testOverrideEncodeDecodeRoundTrips() {
        let map: [String: Bool] = [
            Workspace.duplicates.rawValue: false,
            Workspace.compare.rawValue: true,
        ]
        let decoded = TopPaneVisibility.decodeOverrides(TopPaneVisibility.encodeOverrides(map))
        #expect(decoded == map)
    }

    @Test func testEncodingIsStableAcrossCalls() {
        // Sorted keys keep the persisted string identical for identical contents, so an
        // unchanged map doesn't churn @AppStorage.
        let map: [String: Bool] = ["Storage": true, "Differences": false]
        #expect(TopPaneVisibility.encodeOverrides(map) == TopPaneVisibility.encodeOverrides(map))
    }

    @Test func testUnknownKeysAreIgnoredNotFatal() {
        // A retired entry (e.g. the old "Storage Lens") stays in the map but is never looked up,
        // so it can't affect any current workspace.
        let raw = TopPaneVisibility.encodeOverrides(["Storage Lens": true, "Duplicates": false])
        let decoded = TopPaneVisibility.decodeOverrides(raw)
        #expect(decoded["Storage Lens"] == true)
        #expect(!TopPaneVisibility.panesHidden(for: .duplicates, override: decoded["Duplicates"]))
    }

    @Test func testMalformedAndEmptyOverridesDecodeToEmptyMap() {
        #expect(TopPaneVisibility.decodeOverrides("") == [:])
        #expect(TopPaneVisibility.decodeOverrides("not json") == [:])
        #expect(TopPaneVisibility.decodeOverrides("{\"Duplicates\":123}") == [:])
    }

    @Test func testSettingOverrideAddsAndReplaces() {
        var overrides: [String: Bool] = [:]
        overrides = TopPaneVisibility.settingOverride(overrides, workspace: .duplicates, hidden: false)
        #expect(overrides[Workspace.duplicates.rawValue] == false)
        overrides = TopPaneVisibility.settingOverride(overrides, workspace: .duplicates, hidden: true)
        #expect(overrides[Workspace.duplicates.rawValue] == true)
        #expect(overrides.count == 1)
    }

    // MARK: Migrating the single `Tidy` entry

    @Test func testTidysOverrideFansOutToEveryLensWorkspace() {
        // One key covered all five lenses. Leaving it alone would silently discard a deliberate
        // "keep the rail up in Tidy" the moment the lenses became peers with their own keys.
        let migrated = TopPaneVisibility.migratingOverrides(["Tidy": true])
        for workspace in Workspace.lensWorkspaces {
            #expect(migrated[workspace.rawValue] == true, "\(workspace.rawValue) lost Tidy's choice")
        }
        // And the spent key is gone, so this cannot re-run against a later, deliberate choice.
        #expect(migrated[TopPaneVisibility.legacyTidyKey] == nil)
        // Compare had its own entry and is not a lens — it must not inherit Tidy's.
        #expect(migrated[Workspace.compare.rawValue] == nil)
    }

    @Test func testAWorkspaceThatAlreadyDecidedKeepsItsOwnAnswer() {
        // A second migration pass (or a hand-edited map) must not overwrite a real choice with
        // the legacy one.
        let migrated = TopPaneVisibility.migratingOverrides(["Tidy": true, "Storage": false])
        #expect(migrated["Storage"] == false)
        #expect(migrated["Duplicates"] == true)
    }

    @Test func testAMapWithNoTidyEntryIsLeftExactlyAlone() {
        let already = [Workspace.compare.rawValue: true, Workspace.filing.rawValue: false]
        #expect(TopPaneVisibility.migratingOverrides(already) == already)
        // And the raw-string form reports "nothing to do" rather than rewriting the same value,
        // which would churn @AppStorage on every launch.
        #expect(TopPaneVisibility.migratingOverridesRaw(TopPaneVisibility.encodeOverrides(already)) == nil)
        #expect(TopPaneVisibility.migratingOverridesRaw("") == nil)
    }

    @Test func testTheRawMigrationRoundTripsThroughTheStoredString() throws {
        let raw = TopPaneVisibility.encodeOverrides(["Tidy": true, "Differences": false])
        let migrated = try #require(TopPaneVisibility.migratingOverridesRaw(raw))
        let decoded = TopPaneVisibility.decodeOverrides(migrated)
        #expect(decoded["Tidy"] == nil)
        #expect(decoded["Differences"] == false)
        #expect(decoded["Storage"] == true)
        // Rename is not a workspace, so the fan-out must not mint a key for it — an override for
        // a place that cannot be selected is a row of dead state that would outlive every reader.
        #expect(decoded[Workspace.retiredRenameRawValue] == nil)
    }
}
