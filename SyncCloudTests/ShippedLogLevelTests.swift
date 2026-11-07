import Testing
import Foundation
import Events
@testable import SyncCloud

/// What the shipped Info level keeps: the launch's level decision, autosave's tally, and the one-off
/// records C1 promoted out of Debug.
///
/// Every test process runs at Debug (`Logger.persistedMinimumLevel` under a test runner), so a
/// promoted line demoted again would still be captured and no `LogCapture` test would fail. Where a
/// test can drive the line, its own suite asserts the level (`PaneTabWiringTests`,
/// `OrphanSweeperTests`, `FolderJumpFailureReportTests`). The rest are reached only through a view
/// or a race, so their level is pinned here in the source.
@Suite struct ShippedLogLevelTests {

    // MARK: - The launch's level

    @Test func anUnarmedLaunchRunsAtThePersistedLevelAndSaysNothingMore() {
        let decided = LaunchLogLevel.decision(persisted: .info, armedTraces: [])
        #expect(decided.level == .info)
        #expect(decided.line == nil)
    }

    /// An armed trace's readers compare the Debug decision lines too, so the launch lowers to Debug
    /// and says why the level differs from Settings.
    @Test func anArmedTraceLowersThisLaunchToDebugAndSaysSo() throws {
        let decided = LaunchLogLevel.decision(persisted: .warning, armedTraces: ["displayCycleTraceEnabled"])
        #expect(decided.level == .debug)
        let line = try #require(decided.line)
        #expect(line.contains("displayCycleTraceEnabled"))
        #expect(line.contains("Warnings"), "the line does not say which level Settings holds")
    }

    @Test func anArmedTraceAtDebugAlreadyNeedsNoLine() {
        #expect(LaunchLogLevel.decision(persisted: .debug, armedTraces: ["paneScrollTraceEnabled"]).line == nil)
    }

    // MARK: - Autosave's tally

    @MainActor
    @Test func aDocumentsFirstAutosaveIsInfoAndTheRestAreCountedIntoOneLine() throws {
        let path = "/ShippedLogLevelTests/\(UUID().uuidString).md"
        #expect(EditorAutosaveTally.note(path) == .info)
        #expect(EditorAutosaveTally.note(path) == .debug)
        #expect(EditorAutosaveTally.note(path) == .debug)
        let line = try #require(EditorAutosaveTally.closeOut(path))
        #expect(line.hasPrefix("Editor autosaved \(path) 2 more time(s)"), "\(line)")
        #expect(EditorAutosaveTally.closeOut(path) == nil, "a closed-out document was reported twice")
        #expect(EditorAutosaveTally.note(path) == .info, "a reopened document's first autosave is not Info again")
        #expect(EditorAutosaveTally.closeOut(path) == nil, "one autosave needs no closing line")
    }

    // MARK: - Promoted lines reached only through a view or a race

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// `(file, the call's opening, a fragment unique to its message)`.
    static let promoted: [(file: String, call: String, fragment: String)] = [
        ("Modules/FileExplorer/Sources/FileExplorer/CompareCopiesSheet.swift", "Logger.shared.info(\"\"\"", "aligned before comparing"),
        ("MacApp/ContentView.swift", "Logger.shared.info(\"People: discarded", "discarded a finished gather"),
        ("MacApp/ContentView.swift", "Logger.shared.info(\"People: the gather", "was cancelled"),
        ("Modules/Sync/Sources/Sync/FileSyncManager+Scanning.swift", "Logger.shared.info(\"Swept", "orphaned .tmp_ working"),
        ("Modules/Settings/Sources/Settings/LoginItemController.swift", "Logger.shared.info(\"Launch-at-login: no round-trip", "no round-trip started"),
        ("Modules/FileExplorer/Sources/FileExplorer/OneWaySyncController.swift", "Logger.shared.info(\"One-way sync: Sync Now not run", "Sync Now not run"),
        ("Modules/Sync/Sources/Sync/PaneColumnGraft.swift", "Logger.shared.info(\"[graft]", "could not be read at"),
        ("Modules/Sync/Sources/Sync/FileSyncManager+Verify.swift", "Logger.shared.info(\"Scan checksum pass: discarded", "epoch moved mid-hash"),
    ]

    @Test func everyPromotedLineIsWrittenAtInfo() throws {
        for site in Self.promoted {
            let source = try String(contentsOf: Self.root.appendingPathComponent(site.file), encoding: .utf8)
            // The positive control: the message is still there, so a missing call below is a demotion,
            // not a moved line.
            #expect(source.contains(site.fragment), "\(site.file) no longer writes “\(site.fragment)” — move this pin with it")
            let lines = source.components(separatedBy: "\n")
            let at = lines.indices.filter { lines[$0].contains(site.fragment) }
            let written = at.contains { i in
                lines[max(0, i - 2)...i].contains { $0.contains(site.call) }
            }
            #expect(written, "\(site.file): “\(site.fragment)” is no longer written by \(site.call)…) — the shipped Info level drops it, and it is the only record")
        }
    }
}
