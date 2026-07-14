import Foundation
import Testing
@testable import Sync

/// Exercises the manager's preview end-to-end over a real temp folder: it walks, evaluates on-device,
/// produces verdicts — and, being preview-only, never moves or creates anything.
@Suite @MainActor struct AutomationDryRunTests {

    // Mid-2024, mid-day UTC — stable year across timezones.
    private let now = Date(timeIntervalSince1970: 1_720_000_000)

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, in dir: URL, modified: Date? = nil) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func makeManager(rules: [AutomationRule]) -> FileSyncManager {
        let m = FileSyncManager()
        m.didLoadAutomationRules = true   // bypass UserDefaults; drive these rules directly
        m.automationRules = rules
        return m
    }

    @Test func matchesPdfResolvesYearSkipsNonMatch() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("invoice_acme.pdf", in: dir, modified: now)   // fixed mtime → {year} == 2024
        try write("photo.jpg", in: dir)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)],
                           destinationTemplate: "Documents/Invoices/{year}")
        ])
        await m.runAutomationDryRun(root: dir, providerName: "iCloud", now: now)

        let report = try #require(m.automationDryRun)
        #expect(report.filesScanned == 2)
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.fileName == "invoice_acme.pdf")
        #expect(report.wouldFileCount == 1)
        if case .wouldFile(let dest) = report.rows.first?.verdict {
            #expect(dest == "Documents/Invoices/2024")
        } else {
            Issue.record("expected a wouldFile verdict")
        }
        #expect(m.hasRunAutomationDryRun)
    }

    @Test func collisionAtDestinationBecomesNeedsAttention() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("report.pdf", in: dir)
        // Pre-create the resolved destination holding a same-named file → a real collision.
        let destDir = dir.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try write("report.pdf", in: destDir)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)], destinationTemplate: "Docs")
        ])
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)

        let report = try #require(m.automationDryRun)
        #expect(report.rows.count == 1)
        #expect(report.needsAttentionCount == 1)
        if case .needsAttention = report.rows.first?.verdict {} else {
            Issue.record("expected a needsAttention verdict for the collision")
        }
    }

    @Test func disabledRulesIgnoredAndNothingIsCreatedOrMoved() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.pdf", in: dir)
        let m = makeManager(rules: [
            AutomationRule(name: "off", enabled: false, conditions: [.kindIs(.pdf)], destinationTemplate: "Docs")
        ])
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)

        let report = try #require(m.automationDryRun)
        #expect(report.rows.isEmpty)
        // Preview only: the source file is untouched and no destination folder was ever created.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Docs").path))
    }

    @Test func destinationAnchorsAtProviderRootNotScannedSubfolder() async throws {
        // Regression: previewing while focused into a subfolder used to anchor the destination at
        // that subfolder, nesting the whole rule tree under it (e.g. TODO/Home/…). Destinations must
        // anchor at the provider root regardless of which subfolder is scanned.
        let providerRoot = try tempDir(); defer { try? FileManager.default.removeItem(at: providerRoot) }
        let scanned = providerRoot.appendingPathComponent("TODO")
        try FileManager.default.createDirectory(at: scanned, withIntermediateDirectories: true)
        try write("bill.pdf", in: scanned)
        let m = makeManager(rules: [
            AutomationRule(name: "r", conditions: [.kindIs(.pdf)], destinationTemplate: "Home/Utilities")
        ])
        m.undoManager = UndoManager()
        await m.runAutomationDryRun(root: scanned, destinationRoot: providerRoot, providerName: nil, now: now)

        let report = try #require(m.automationDryRun)
        let row = try #require(report.rows.first)
        // The baked destination is under the provider root, not the scanned subfolder.
        #expect(row.destinationDir?.standardizedFileURL.path
                == providerRoot.appendingPathComponent("Home/Utilities").standardizedFileURL.path)
        #expect(row.destinationDir?.path.contains("/TODO/") == false)

        let outcome = await m.applyAutomationFiling(rows: report.rows)
        #expect(outcome.filed == 1)
        // Filed into the provider-root tree; nothing created under the scanned subfolder.
        #expect(FileManager.default.fileExists(
            atPath: providerRoot.appendingPathComponent("Home/Utilities/bill.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: scanned.appendingPathComponent("Home").path))
    }

    // MARK: Filing (phase B)

    @Test func applyFilingMovesApprovedFilesAndClearsAllFiledReport() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.pdf", in: dir)
        try write("b.pdf", in: dir)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)], destinationTemplate: "Filed")
        ])
        m.undoManager = UndoManager()
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)
        let report = try #require(m.automationDryRun)
        let actionable = report.rows.filter { $0.destinationDir != nil }
        #expect(actionable.count == 2)

        let outcome = await m.applyAutomationFiling(rows: actionable)
        #expect(outcome.filed == 2)
        #expect(outcome.failed == 0)
        // Files moved into Filed/, sources gone.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Filed/a.pdf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Filed/b.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.pdf").path))
        // Everything filed → the preview is cleared.
        #expect(m.automationDryRun == nil)
    }

    @Test func filingKeepsBothOnNameCollision() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("report.pdf", in: dir)
        let filed = dir.appendingPathComponent("Filed")
        try FileManager.default.createDirectory(at: filed, withIntermediateDirectories: true)
        try write("report.pdf", in: filed)   // an existing file with the same name at the destination
        let m = makeManager(rules: [
            AutomationRule(name: "r", conditions: [.kindIs(.pdf)], destinationTemplate: "Filed")
        ])
        m.undoManager = UndoManager()
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)
        let report = try #require(m.automationDryRun)
        // The row is a collision (needsAttention) but still actionable (destinationDir set).
        let actionable = report.rows.filter { $0.destinationDir != nil }
        #expect(actionable.count == 1)

        let outcome = await m.applyAutomationFiling(rows: actionable)
        #expect(outcome.filed == 1)
        // Never overwrites: the original stays, the moved one is kept as "report 2.pdf".
        #expect(FileManager.default.fileExists(atPath: filed.appendingPathComponent("report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: filed.appendingPathComponent("report 2.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("report.pdf").path))
    }

    @Test func filingIgnoresNonActionableRows() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("scan.pdf", in: dir, modified: now)
        // {year} resolves from the file date, so use a token the file can't supply → unresolved.
        let m = makeManager(rules: [
            AutomationRule(name: "r", conditions: [.kindIs(.pdf)], destinationTemplate: "{provider}/x")
        ])
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)   // no provider → unresolved
        let report = try #require(m.automationDryRun)
        #expect(report.rows.count == 1)
        #expect(report.rows.allSatisfy { $0.destinationDir == nil })
        let outcome = await m.applyAutomationFiling(rows: report.rows)
        #expect(outcome.filed == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("scan.pdf").path))
    }
}
