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
}
