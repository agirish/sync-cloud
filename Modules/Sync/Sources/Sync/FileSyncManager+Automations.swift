import Events
import Foundation

/// N2 Automations — **preview-only** orchestration. Loads/persists the user's rules and runs a
/// dry-run over a folder: what the enabled rules *would* do, with nothing moved. Everything here is
/// on-device — filename globs, UTType, file attributes, and (only when a rule asks) the injected
/// on-device snippet extractor. The cloud filing classifier is never constructed on this path.
extension FileSyncManager {

    /// Where automation rules persist (JSON, in the injectable `filingRuleDefaults` store — the same
    /// store Filing's rules use, so tests that stub defaults cover both).
    public static let automationRulesDefaultsKey = "automationRules"

    // MARK: Rule store

    /// The persisted rules, decoded from defaults. A corrupt/absent value decodes to `[]`.
    private var persistedAutomationRules: [AutomationRule] {
        get {
            guard let data = filingRuleDefaults.data(forKey: Self.automationRulesDefaultsKey),
                  let rules = try? JSONDecoder().decode([AutomationRule].self, from: data) else { return [] }
            return rules
        }
        set { filingRuleDefaults.set(try? JSONEncoder().encode(newValue), forKey: Self.automationRulesDefaultsKey) }
    }

    /// Loads rules from defaults into the published array exactly once. Safe to call repeatedly
    /// (the lens calls it on appear); the guard means an early empty read can't clobber later state.
    public func ensureAutomationRulesLoaded() {
        guard !didLoadAutomationRules else { return }
        didLoadAutomationRules = true
        automationRules = persistedAutomationRules
    }

    /// Adds a new rule (or replaces one with the same id) and persists.
    public func upsertAutomationRule(_ rule: AutomationRule) {
        ensureAutomationRulesLoaded()
        if let idx = automationRules.firstIndex(where: { $0.id == rule.id }) {
            automationRules[idx] = rule
        } else {
            automationRules.append(rule)
        }
        persistedAutomationRules = automationRules
    }

    /// Removes a rule and persists.
    public func removeAutomationRule(id: UUID) {
        ensureAutomationRulesLoaded()
        automationRules.removeAll { $0.id == id }
        persistedAutomationRules = automationRules
    }

    /// Enables/disables a rule (kept, not deleted) and persists.
    public func setAutomationRule(id: UUID, enabled: Bool) {
        ensureAutomationRulesLoaded()
        guard let idx = automationRules.firstIndex(where: { $0.id == id }) else { return }
        automationRules[idx].enabled = enabled
        persistedAutomationRules = automationRules
    }

    // MARK: Dry run

    /// Starts a cancellable dry-run preview of the enabled rules over `root`, replacing any in-flight
    /// one. `root` is the folder whose loose files are scanned; `destinationRoot` is the anchor a
    /// rule's (provider-relative) destination template resolves against — the **provider root**, not
    /// the scanned folder, so previewing while focused into a subfolder still files into the same
    /// place. `providerName` labels the surface and resolves the `{provider}` token.
    /// `only` scopes the preview to a single rule (its id); nil previews all enabled, runnable rules.
    public func startAutomationDryRun(root: URL, destinationRoot: URL, providerName: String?, only: UUID? = nil) {
        let previous = automationDryRunTask
        previous?.cancel()
        automationDryRunTask = Task { [weak self] in
            _ = await previous?.value   // let a cancelled run unwind before the guard below
            await self?.runAutomationDryRun(root: root, destinationRoot: destinationRoot,
                                            providerName: providerName, only: only)
        }
    }

    /// Cancels a running preview; the previous report (if any) is left intact.
    public func cancelAutomationDryRun() {
        automationDryRunTask?.cancel()
    }

    /// Clears the current preview (called on provider switch, so a stale report from one provider
    /// can't show under another).
    public func clearAutomationDryRun() {
        automationDryRunTask?.cancel()
        automationDryRun = nil
        hasRunAutomationDryRun = false
    }

    /// Walks `root`'s loose files, evaluates the enabled rules on-device, and publishes the report.
    /// Content is read only for files a content-condition could still match — cheap conditions gate
    /// the expensive text extraction.
    func runAutomationDryRun(
        root: URL,
        destinationRoot: URL? = nil,
        providerName: String?,
        only: UUID? = nil,
        fileManager fm: FileManaging? = nil,
        now: Date = Date()
    ) async {
        guard !isRunningAutomationDryRun else { return }
        ensureAutomationRulesLoaded()
        let fileManager = fm ?? self.fileManager
        // Destinations resolve against the provider root; callers that don't distinguish (tests
        // scanning a self-contained temp dir) anchor at the scanned folder itself.
        let destinationAnchor = destinationRoot ?? root
        // A single-rule preview (only != nil) runs even if that rule is toggled off, so a rule can be
        // tested before enabling it; "preview all" (only == nil) uses just the enabled rules.
        let rules = automationRules.filter { rule in
            guard rule.isRunnable else { return false }
            return only == nil ? rule.enabled : rule.id == only
        }

        isRunningAutomationDryRun = true
        automationDryRunStatus = "Previewing \(root.lastPathComponent)…"
        defer {
            isRunningAutomationDryRun = false
            automationDryRunStatus = ""
        }

        // Loose files = the direct files in the folder (not its subfolders), mirroring Filing.
        let looseTree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager, maxDepth: 1)
        let looseFiles = looseTree.filter { !$0.isDirectory && !FilingOptions.defaultIgnoredNames.contains($0.name) }
        if Task.isCancelled { return }

        let readsContents = filingReadsContents
        let snippetExtractor = filingSnippetExtractor
        let parentFolderName = root.lastPathComponent
        let parentPath = root.path

        var rows: [AutomationDryRunRow] = []
        for file in looseFiles {
            if Task.isCancelled { return }
            var facts = AutomationFileFacts(
                path: file.id,
                name: file.name,
                parentFolderName: parentFolderName,
                parentPath: parentPath,
                sizeBytes: file.fileSize ?? 0,
                modificationDate: file.modificationDate,
                isDirectory: file.isDirectory
            )

            // Read the file's on-device text only when a content condition could still decide a
            // match for it — the cheap conditions above have already been factored in.
            if readsContents, let extractor = snippetExtractor,
               rules.contains(where: { $0.requiresContent
                   && AutomationEvaluator.couldMatchPendingContent($0, facts, now: now) }) {
                facts.snippet = (await extractor(file.id))?.lowercased()
                if Task.isCancelled { return }
            }

            // First rule, in user order, whose conditions match. `rules` is already scoped correctly
            // (enabled rules for a full preview, or exactly the one rule for a single-rule preview),
            // so this must NOT re-filter on `enabled` — doing so would make a single-rule preview of a
            // disabled rule (the "test it before enabling" flow) silently match nothing.
            guard let rule = rules.first(where: { AutomationEvaluator.matches($0, facts, now: now) }) else { continue }
            let resolution = Self.dryRunVerdict(
                for: rule, facts: facts, destinationRoot: destinationAnchor,
                providerName: providerName, now: now, fileManager: fileManager
            )
            rows.append(AutomationDryRunRow(
                id: file.id, fileName: file.name,
                ruleID: rule.id, ruleName: rule.name, verdict: resolution.verdict,
                destinationDir: resolution.destinationDir, destinationLabel: resolution.label
            ))
        }

        let report = AutomationDryRunReport(
            root: root.path, providerName: providerName,
            filesScanned: looseFiles.count, rows: rows
        )
        self.automationDryRun = report
        self.hasRunAutomationDryRun = true
        Logger.shared.info("Automations dry run: \(root.lastPathComponent) — \(looseFiles.count) file(s), "
            + "\(report.wouldFileCount) would file, \(report.needsAttentionCount) need a look "
            + "(preview only, nothing moved)")
    }

    /// Turns a resolved destination into a preview verdict, adding the two disk/root-aware outcomes
    /// the pure evaluator can't know: "already there" and a name collision. `nonisolated static` so
    /// it can run inside the off-main loop with the injected file manager.
    nonisolated static func dryRunVerdict(
        for rule: AutomationRule,
        facts: AutomationFileFacts,
        destinationRoot: URL,
        providerName: String?,
        now: Date,
        fileManager: FileManaging
    ) -> (verdict: AutomationVerdict, destinationDir: URL?, label: String?) {
        switch AutomationEvaluator.resolveDestination(rule.destinationTemplate, for: facts,
                                                      providerName: providerName, now: now) {
        case .unresolved(let token):
            return (.needsAttention("needs \(token), which this file doesn't have"), nil, nil)
        case .resolved(let relativeDestination):
            let destinationDir = destinationRoot.appendingPathComponent(relativeDestination).standardizedFileURL
            let currentParent = URL(fileURLWithPath: facts.parentPath).standardizedFileURL
            let label = relativeDestination.isEmpty ? (providerName.map { "\($0) root" } ?? "the folder root")
                                                    : relativeDestination
            if destinationDir.path == currentParent.path {
                return (.alreadyThere, nil, nil)
            }
            let target = destinationDir.appendingPathComponent(facts.name)
            if fileManager.fileExists(atPath: target.path) {
                // Filable — the move keeps both (never overwrites); flagged so the review card can say so.
                return (.needsAttention("a file named “\(facts.name)” is already there"), destinationDir, label)
            }
            return (.wouldFile(destination: label), destinationDir, label)
        }
    }

    // MARK: Filing (phase B — moves real files, one reversible run)

    /// Files the given previewed rows for real: each actionable row (its `destinationDir` set) is
    /// moved into that folder through the same safe primitives the rest of the app uses — creating
    /// intermediate folders, **never overwriting** (a name clash is kept as a copy), registering one
    /// undo action for the whole run, and logging every move to Sync History. The per-file
    /// confirmation happens in the UI *before* this is called; here we just execute the approved set.
    /// Returns the number filed and the number that failed.
    @discardableResult
    public func applyAutomationFiling(rows: [AutomationDryRunRow]) async -> (filed: Int, failed: Int) {
        // Don't move files Verify All may be checksumming (same guard Filing uses).
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before filing")
            return (0, 0)
        }
        let fm = fileManager
        let logger = Logger.shared
        let actionable = rows.filter { $0.destinationDir != nil }
        guard !actionable.isEmpty else { return (0, 0) }

        var moves: [MoveItemState] = []
        var records: [SyncHistoryRecord] = []
        var filedPaths: Set<String> = []
        var failures = 0
        let runId = UUID()

        for row in actionable {
            guard let destFolder = row.destinationDir else { continue }
            let src = URL(fileURLWithPath: row.id)
            let name = row.fileName
            let outcome: (movedTo: URL?, overwritten: URL?, failed: Bool) = await enqueueFileOperation {
                do {
                    guard fm.fileExists(atPath: src.path) else { return (nil, nil, true) }
                    try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                    var dst = destFolder.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)   // keep both
                    }
                    let overwritten = try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: fm)
                    return (dst, overwritten, false)
                } catch {
                    logger.warning("Automation filing: moving “\(name)” into \(destFolder.lastPathComponent) failed: \(error.localizedDescription)")
                    return (nil, nil, true)
                }
            }
            if let moved = outcome.movedTo, !outcome.failed {
                moves.append((from: src, to: moved, overwritten: outcome.overwritten))
                let size = ((try? fm.attributesOfItem(atPath: moved.path))?[.size] as? NSNumber)?.intValue
                records.append(SyncHistoryRecord(
                    runId: runId, action: .move, sourcePath: src.path, destPath: moved.path,
                    sizeBytes: size, checksum: nil, backupPath: outcome.overwritten?.path, direction: nil
                ))
                filedPaths.insert(row.id)
            } else {
                failures += 1
            }
        }

        guard !moves.isEmpty else {
            if failures > 0 { banner = .warning("Couldn't file \(failures) file\(failures == 1 ? "" : "s").") }
            return (0, failures)
        }
        // One undo action reverts the whole run, so ⌘Z is honest.
        registerMoveUndo(items: moves, actionName: "File \(moves.count) file\(moves.count == 1 ? "" : "s") by automation",
                         fileManager: fm)
        recordSyncHistory(records)

        // Reflect what's left: drop the filed rows from the current preview (their files have moved).
        if let report = automationDryRun {
            let remaining = report.rows.filter { !filedPaths.contains($0.id) }
            if remaining.isEmpty {
                automationDryRun = nil
                hasRunAutomationDryRun = false
            } else {
                automationDryRun = AutomationDryRunReport(root: report.root, providerName: report.providerName,
                                                          filesScanned: report.filesScanned, rows: remaining)
            }
        }

        let n = moves.count
        logger.info("Automation filing: filed \(n) file(s)\(failures > 0 ? ", \(failures) failed" : "")")
        banner = failures > 0
            ? .warning("Filed \(n) file\(n == 1 ? "" : "s"); \(failures) couldn't be filed. Press ⌘Z to undo")
            : .success("Filed \(n) file\(n == 1 ? "" : "s"). Press ⌘Z to undo")
        return (n, failures)
    }
}
