import Combine
import Foundation
import Testing
@testable import Sync

/// Exercises the manager's automation runs end-to-end over a real temp folder: the dry-run preview
/// (walks, evaluates on-device, produces verdicts, moves nothing) and phase B, which files the
/// approved rows for real.
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
        #expect(m.automationDryRunLifecycle.hasCompleted)
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
        // Load-bearing: a collision is still *actionable* (keep-both on file), so destinationDir is set.
        #expect(report.rows.first?.destinationDir != nil)
    }

    @Test func singleRulePreviewRunsEvenWhenTheRuleIsDisabled() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.pdf", in: dir)
        let rule = AutomationRule(name: "off", enabled: false,
                                  conditions: [.kindIs(.pdf)], destinationTemplate: "Docs")
        let m = makeManager(rules: [rule])
        // only: the rule's id previews it even though it's toggled off — the "test before enabling" flow.
        await m.runAutomationDryRun(root: dir, providerName: nil, only: rule.id, now: now)
        let report = try #require(m.automationDryRun)
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.ruleID == rule.id)
        // But a full preview (only == nil) still skips the disabled rule.
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)
        #expect(m.automationDryRun?.rows.isEmpty == true)
    }

    @Test func singleRulePreviewScopesToOneRuleAndFullPreviewHonorsPriority() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.pdf", in: dir)
        let ruleA = AutomationRule(name: "A", conditions: [.kindIs(.pdf)], destinationTemplate: "A")
        let ruleB = AutomationRule(name: "B", conditions: [.kindIs(.pdf)], destinationTemplate: "B")
        let m = makeManager(rules: [ruleA, ruleB])
        // only: B scopes the preview to B, even though A also matches.
        await m.runAutomationDryRun(root: dir, providerName: nil, only: ruleB.id, now: now)
        let scoped = try #require(m.automationDryRun)
        #expect(scoped.rows.count == 1)
        #expect(scoped.rows.allSatisfy { $0.ruleID == ruleB.id })
        // A full preview: the first rule in order (A) claims the file.
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)
        #expect(m.automationDryRun?.rows.first?.ruleID == ruleA.id)
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

    @Test func filingRefusesToRebuildAProviderThatWentAwayAfterThePreview() async throws {
        // The provider unmounts (or the cloud folder is removed) between the preview and the apply.
        // `createDirectory(withIntermediateDirectories: true)` will happily rebuild the whole path as
        // an ordinary local folder, so without a guard the file is MOVED out of a live tree into a
        // dead one nothing syncs — and reported as filed.
        //
        // The scanned folder is a SIBLING of the provider root, not a child: with the source inside
        // the root, deleting the root also deletes the source, and the pre-existing
        // `fileExists(atPath: src.path)` check would refuse first — the new guard would never be
        // reached and this test would pass with it removed.
        let base = try tempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let inbox = base.appendingPathComponent("Inbox")
        let providerRoot = base.appendingPathComponent("Provider")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerRoot, withIntermediateDirectories: true)
        try write("bill.pdf", in: inbox, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "r", conditions: [.kindIs(.pdf)], destinationTemplate: "Filed")
        ])
        m.undoManager = UndoManager()
        await m.runAutomationDryRun(root: inbox, destinationRoot: providerRoot, providerName: nil, now: now)
        let report = try #require(m.automationDryRun)
        let actionable = report.rows.filter { $0.destinationDir != nil }
        #expect(actionable.count == 1)

        // The provider goes away, exactly as an eject or a removed cloud folder would leave it.
        try FileManager.default.removeItem(at: providerRoot)

        let outcome = await m.applyAutomationFiling(rows: actionable)
        #expect(outcome.filed == 0)
        #expect(outcome.failed == 1)
        // Nothing was rebuilt: neither the root nor the rule's folder under it.
        #expect(!FileManager.default.fileExists(atPath: providerRoot.path))
        #expect(!FileManager.default.fileExists(atPath: providerRoot.appendingPathComponent("Filed").path))
        // And the file is still where the user left it.
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("bill.pdf").path))
        // The banner names the cause rather than flattening it into "couldn't file 1 file".
        let banner = try #require(m.banner)
        #expect(banner.severity == .warning)
        #expect(banner.message.contains("no longer available"))
        // The other direction of the guard — that it does NOT refuse a provider that is still
        // there — is pinned by every filing test above; each anchors on a root that exists, and a
        // guard stuck closed fails all of them.
    }

    // MARK: Mentions rules & content reading

    @Test func mentionsRuleMatchesByNameWithoutReadingContent() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("Tesla Policy.pdf", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                           destinationTemplate: "Cars/Tesla")
        ])
        // A name-decided match must NOT pay for text extraction (the outcome can't change).
        let flag = Flag()
        m.filingSnippetExtractor = { _ in flag.value = true; return "irrelevant" }
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)

        let report = try #require(m.automationDryRun)
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.verdict == .wouldFile(destination: "Cars/Tesla"))
        #expect(!flag.value)
    }

    @Test func mentionsRuleMatchesViaExtractedText() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("scan0042.pdf", in: dir, modified: now)
        try write("photo.jpg", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "Lease", conditions: [.mentionsAll(["lease"])],
                           destinationTemplate: "Home/Lease")
        ])
        m.filingSnippetExtractor = { path in
            path.hasSuffix("scan0042.pdf") ? "LEASE agreement for unit 4" : nil
        }
        await m.runAutomationDryRun(root: dir, providerName: nil, now: now)

        let report = try #require(m.automationDryRun)
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.fileName == "scan0042.pdf")
        #expect(report.rows.first?.verdict == .wouldFile(destination: "Home/Lease"))
    }

    // MARK: Absolute destinations (learned/migrated rules)

    @Test func absoluteRuleInsideTheProviderPreviewsWithARelativeLabel() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = dir.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try write("tesla note.pdf", in: inbox, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                           destinationTemplate: dir.appendingPathComponent("Cars/Tesla").path)
        ])
        await m.runAutomationDryRun(root: inbox, destinationRoot: dir, providerName: "iCloud", now: now)

        let report = try #require(m.automationDryRun)
        #expect(report.rows.count == 1)
        // The absolute in-provider destination previews under its provider-relative label…
        #expect(report.rows.first?.verdict == .wouldFile(destination: "Cars/Tesla"))
        // …and resolves to the absolute folder for the real move.
        #expect(report.rows.first?.destinationDir?.path == dir.appendingPathComponent("Cars/Tesla").path)
    }

    @Test func absoluteRuleAlreadyThereAndOutsideProviderRules() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cars = dir.appendingPathComponent("Cars/Tesla")
        try FileManager.default.createDirectory(at: cars, withIntermediateDirectories: true)
        try write("tesla note.pdf", in: cars, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                           destinationTemplate: cars.path),
            AutomationRule(name: "Elsewhere", conditions: [.mentionsAll(["tesla"])],
                           destinationTemplate: "/AnotherProvider/Cars")
        ])
        await m.runAutomationDryRun(root: cars, destinationRoot: dir, providerName: nil, now: now)

        let report = try #require(m.automationDryRun)
        // The in-provider rule sees the file already home; the other-provider rule was filtered
        // out entirely (it must not claim the file).
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.verdict == .alreadyThere)
    }

    @Test func singleRulePreviewOfAProviderInertRuleExplainsItself() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("tesla note.pdf", in: dir, modified: now)
        let inert = AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                                   destinationTemplate: "/AnotherProvider/Cars/Tesla")
        let m = makeManager(rules: [inert])
        await m.runAutomationDryRun(root: dir, providerName: "iCloud", only: inert.id, now: now)

        // No silent empty report — the user is told the rule can't act in this provider.
        #expect(m.automationDryRun == nil)
        #expect(m.banner?.severity == .warning)
        #expect(m.banner?.message.contains("outside") == true)
    }

    // MARK: - A preview is not applied at the moment it is taken

    /// **Every previewed row records what the file was**, which is the premise the guard below
    /// rests on. Without this the refusal could quietly stop applying to production rows — a nil
    /// identity means "not recorded" and proceeds — and nothing would say so.
    @Test func everyPreviewedRowCarriesTheIdentityItWasReadWith() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("invoice_acme.pdf", in: dir, modified: now)
        try write("invoice_beta.pdf", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)],
                           destinationTemplate: "Documents/Invoices/{year}")
        ])
        await m.runAutomationDryRun(root: dir, providerName: "iCloud", now: now)

        let report = try #require(m.automationDryRun)
        #expect(!report.rows.isEmpty, "fixture: nothing was previewed")
        for row in report.rows {
            let identity = try #require(row.sourceIdentity,
                                        "a previewed row carries no identity, so apply cannot check it")
            #expect(identity != .absent, "the preview read the file as not there")
            #expect(identity != .indeterminate, "the preview could not read the file it matched")
        }
    }

    /// **A file that changed since the preview is left where it is.**
    ///
    /// The apply gated on `fileExists(atPath:)`, and a path is not a file. Between the preview and
    /// the click — which the walkthrough stretches over as many rows as the user has — anything
    /// taking that path got moved instead: out of the folder they were looking at, into a
    /// destination chosen for a document it is not, and being a move, with nothing left behind.
    @Test func aFileReplacedSinceThePreviewIsNotFiled() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("invoice_acme.pdf", in: dir, modified: now)
        try write("invoice_beta.pdf", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)],
                           destinationTemplate: "Documents/Invoices/{year}")
        ])
        await m.runAutomationDryRun(root: dir, providerName: "iCloud", now: now)
        let actionable = try #require(m.automationDryRun).rows.filter { $0.destinationDir != nil }
        #expect(actionable.count == 2, "fixture: both PDFs should be filable")

        // A different document takes one of the paths — same name, different contents.
        let replaced = dir.appendingPathComponent("invoice_acme.pdf")
        try Data(String(repeating: "different", count: 40).utf8).write(to: replaced)

        let outcome = await m.applyAutomationFiling(rows: actionable)

        #expect(FileManager.default.fileExists(atPath: replaced.path),
                "the replacement was filed — it is not the document that rule matched")
        #expect(outcome.filed == 1, "the untouched file is still the rule's to file")
        #expect(outcome.failed == 0, "a refusal is not a failure; nothing went wrong with the disk")
    }

    /// And it is SAID — in the banner and the log. A refusal nobody is told about leaves a smaller
    /// number that reads as "there was less to do", which is the same silence the guard replaces.
    @Test func aRefusedAutomationFilingSaysSo() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("invoice_acme.pdf", in: dir, modified: now)
        try write("invoice_beta.pdf", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)],
                           destinationTemplate: "Documents/Invoices/{year}")
        ])
        await m.runAutomationDryRun(root: dir, providerName: "iCloud", now: now)
        let actionable = try #require(m.automationDryRun).rows.filter { $0.destinationDir != nil }
        try Data(String(repeating: "different", count: 40).utf8)
            .write(to: dir.appendingPathComponent("invoice_acme.pdf"))

        let tag = "automation-refusal-\(UUID().uuidString)"
        let lines = try await logLines(tag: tag) {
            _ = await m.applyAutomationFiling(rows: actionable)
        }
        #expect(lines.contains { $0.contains("REFUSED to move") && $0.contains("invoice_acme.pdf") },
                "the log did not say why a file was left behind")
        let message = try #require(m.banner?.message)
        #expect(message.contains("changed since the preview"),
                "the banner counted one filed and said nothing about the one it refused: \(message)")
    }

    /// The other direction, so the guard cannot become "never file": an untouched preview still
    /// files everything it matched, and says nothing about changes.
    @Test func anUntouchedPreviewStillFilesEverything() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("invoice_acme.pdf", in: dir, modified: now)
        try write("invoice_beta.pdf", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)],
                           destinationTemplate: "Documents/Invoices/{year}")
        ])
        await m.runAutomationDryRun(root: dir, providerName: "iCloud", now: now)
        let actionable = try #require(m.automationDryRun).rows.filter { $0.destinationDir != nil }

        let outcome = await m.applyAutomationFiling(rows: actionable)
        #expect(outcome.filed == 2)
        #expect(outcome.failed == 0)
        #expect(m.banner?.message.contains("changed since the preview") != true,
                "an untouched run reported a refusal")
    }

    /// A row built without an identity — every hand-made fixture in the suite — files as it always
    /// did. The escape hatch is deliberate and this is what keeps it honest about being one.
    @Test func aRowWithNoRecordedIdentityFilesAsBefore() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("invoice_acme.pdf", in: dir, modified: now)
        let m = makeManager(rules: [])
        let dest = dir.appendingPathComponent("Documents/Invoices")
        let row = AutomationDryRunRow(
            id: dir.appendingPathComponent("invoice_acme.pdf").path, fileName: "invoice_acme.pdf",
            ruleID: UUID(), ruleName: "PDFs", verdict: .wouldFile(destination: "Documents/Invoices"),
            destinationDir: dest, destinationLabel: "Documents/Invoices",
            destinationAnchor: dir)
        #expect(row.sourceIdentity == nil, "fixture: this row is the no-identity case")

        let outcome = await m.applyAutomationFiling(rows: [row])
        #expect(outcome.filed == 1)
    }

    // MARK: The public start/cancel/clear seam
    //
    // Everything above drives `runAutomationDryRun` directly, which leaves the wrapper the UI
    // actually calls — `startAutomationDryRun`'s task replacement, `cancelAutomationDryRun`,
    // `clearAutomationDryRun` — with no coverage at all. These three park the scan mid-flight in
    // the injected extractor so cancellation and supersession are exercised deterministically
    // rather than raced against a scan over a tiny folder.

    /// `cancelAutomationDryRun`'s documented contract: the in-flight preview is abandoned and
    /// "the previous report (if any) is left intact".
    @Test func cancellingAPreviewLeavesThePreviousReportIntact() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("Tesla Policy.pdf", in: dir, modified: now)
        let second = try tempDir(); defer { try? FileManager.default.removeItem(at: second) }
        try write("scan0042.pdf", in: second, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "Tesla", conditions: [.mentionsAll(["tesla"])],
                           destinationTemplate: "Cars/Tesla")
        ])

        // First preview completes normally (name-decided, extractor never consulted).
        let entered = Flag(), released = Flag(), timedOut = Flag()
        m.filingSnippetExtractor = { _ in
            entered.value = true
            await parkUntilReleased(released, timedOut: timedOut)
            return nil
        }
        m.startAutomationDryRun(root: dir, destinationRoot: dir, providerName: nil)
        _ = await m.automationDryRunTask?.value
        let first = try #require(m.automationDryRun)
        #expect(first.root == dir.path)

        // Second preview parks in the extractor (its file needs content to decide), is cancelled
        // mid-flight, then unwinds. The first report must survive it.
        m.startAutomationDryRun(root: second, destinationRoot: second, providerName: nil)
        await waitUntil("the second preview reached the extractor") { entered.value }
        m.cancelAutomationDryRun()
        released.value = true
        _ = await m.automationDryRunTask?.value
        try #require(!timedOut.value, "the parked extractor was never released")

        #expect(m.automationDryRun?.root == dir.path,
                "the cancelled preview must not publish, and must not clear the standing report")
    }

    /// `startAutomationDryRun` replaces an in-flight preview: the superseded scan never publishes
    /// and the replacement's report is the one that lands, even when the first is parked mid-file
    /// when the second starts.
    @Test func aSecondPreviewSupersedesAParkedFirstAndPublishesItsOwnReport() async throws {
        let dirA = try tempDir(); defer { try? FileManager.default.removeItem(at: dirA) }
        let dirB = try tempDir(); defer { try? FileManager.default.removeItem(at: dirB) }
        try write("scanA.pdf", in: dirA, modified: now)
        try write("scanB.pdf", in: dirB, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "Lease", conditions: [.mentionsAll(["lease"])],
                           destinationTemplate: "Home/Lease")
        ])
        let enteredA = Flag(), released = Flag(), timedOut = Flag()
        m.filingSnippetExtractor = { path in
            if path.hasSuffix("scanA.pdf") {
                enteredA.value = true
                await parkUntilReleased(released, timedOut: timedOut)
                return nil
            }
            return "lease agreement for unit 4"
        }
        // Collect every publish, because the final state alone cannot see the defect this test
        // exists for: the superseded scan runs first, so even WITHOUT the cancel its report would
        // be overwritten by the replacement's and the end state would look right. A stale report
        // flashing up and being replaced is exactly the supersession bug; the sequence pins it.
        var publishedRoots: [String?] = []
        let subscription = m.$automationDryRun.dropFirst().sink { publishedRoots.append($0?.root) }
        defer { subscription.cancel() }

        m.startAutomationDryRun(root: dirA, destinationRoot: dirA, providerName: nil)
        await waitUntil("the first preview reached the extractor") { enteredA.value }
        m.startAutomationDryRun(root: dirB, destinationRoot: dirB, providerName: nil)
        released.value = true
        _ = await m.automationDryRunTask?.value
        try #require(!timedOut.value, "the parked extractor was never released")

        let report = try #require(m.automationDryRun)
        #expect(report.rows.map(\.fileName) == ["scanB.pdf"])
        #expect(m.automationDryRunLifecycle.hasCompleted)
        #expect(publishedRoots == [dirB.path],
                "the superseded scan must never publish — one report, the replacement's")
    }

    /// `clearAutomationDryRun` (the provider-switch path): the standing report is dropped so a
    /// stale preview from one provider can't show under another.
    @Test func clearDropsTheStandingReportAndItsCompletionFlag() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.pdf", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)], destinationTemplate: "Docs")
        ])
        m.startAutomationDryRun(root: dir, destinationRoot: dir, providerName: nil)
        _ = await m.automationDryRunTask?.value
        try #require(m.automationDryRun != nil)
        try #require(m.automationDryRunLifecycle.hasCompleted)

        m.clearAutomationDryRun()

        #expect(m.automationDryRun == nil)
        #expect(!m.automationDryRunLifecycle.hasCompleted)
    }

    /// `clearAutomationDryRun`'s FIRST line is a task cancel, and clearing after a completed
    /// preview — the test above — never exercises it. This is the half the provider-switch path
    /// actually leans on: a clear that only dropped the standing report would let the old
    /// provider's in-flight scan finish and publish AFTER the clear, which is the stale-preview-
    /// under-another-provider defect with a one-step-longer fuse.
    @Test func clearAbandonsAnInFlightPreviewEntirely() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("scan0042.pdf", in: dir, modified: now)
        let m = makeManager(rules: [
            AutomationRule(name: "Lease", conditions: [.mentionsAll(["lease"])],
                           destinationTemplate: "Home/Lease")
        ])
        let entered = Flag(), released = Flag(), timedOut = Flag()
        m.filingSnippetExtractor = { _ in
            entered.value = true
            await parkUntilReleased(released, timedOut: timedOut)
            return "lease agreement for unit 4"
        }
        // Collect every publish: the end state alone cannot distinguish "the scan was cancelled"
        // from "the scan published and something cleared again afterwards".
        var publishedRoots: [String?] = []
        let subscription = m.$automationDryRun.dropFirst().sink { publishedRoots.append($0?.root) }
        defer { subscription.cancel() }

        m.startAutomationDryRun(root: dir, destinationRoot: dir, providerName: nil)
        await waitUntil("the preview reached the extractor") { entered.value }
        m.clearAutomationDryRun()
        released.value = true
        _ = await m.automationDryRunTask?.value
        try #require(!timedOut.value, "the parked extractor was never released")

        #expect(m.automationDryRun == nil)
        #expect(!m.automationDryRunLifecycle.hasCompleted)
        #expect(publishedRoots.filter { $0 != nil }.isEmpty,
                "a cleared in-flight preview must never publish its report — got \(publishedRoots)")
    }
}
