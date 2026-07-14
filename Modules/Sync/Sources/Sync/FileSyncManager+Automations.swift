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
    /// one. `providerName` labels the surface and resolves the `{provider}` token.
    /// `only` scopes the preview to a single rule (its id); nil previews all enabled, runnable rules.
    public func startAutomationDryRun(root: URL, providerName: String?, only: UUID? = nil) {
        let previous = automationDryRunTask
        previous?.cancel()
        automationDryRunTask = Task { [weak self] in
            _ = await previous?.value   // let a cancelled run unwind before the guard below
            await self?.runAutomationDryRun(root: root, providerName: providerName, only: only)
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
        providerName: String?,
        only: UUID? = nil,
        fileManager fm: FileManaging? = nil,
        now: Date = Date()
    ) async {
        guard !isRunningAutomationDryRun else { return }
        ensureAutomationRulesLoaded()
        let fileManager = fm ?? self.fileManager
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

            guard let rule = AutomationEvaluator.firstMatch(in: rules, for: facts, now: now) else { continue }
            let verdict = Self.dryRunVerdict(
                for: rule, facts: facts, root: root,
                providerName: providerName, now: now, fileManager: fileManager
            )
            rows.append(AutomationDryRunRow(
                id: file.id, fileName: file.name,
                ruleID: rule.id, ruleName: rule.name, verdict: verdict
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
        root: URL,
        providerName: String?,
        now: Date,
        fileManager: FileManaging
    ) -> AutomationVerdict {
        switch AutomationEvaluator.resolveDestination(rule.destinationTemplate, for: facts,
                                                      providerName: providerName, now: now) {
        case .unresolved(let token):
            return .needsAttention("needs \(token), which this file doesn't have")
        case .resolved(let relativeDestination):
            let destinationDir = root.appendingPathComponent(relativeDestination).standardizedFileURL
            let currentParent = URL(fileURLWithPath: facts.parentPath).standardizedFileURL
            if destinationDir.path == currentParent.path {
                return .alreadyThere
            }
            let target = destinationDir.appendingPathComponent(facts.name)
            if fileManager.fileExists(atPath: target.path) {
                return .needsAttention("a file named “\(facts.name)” is already there")
            }
            let shown = relativeDestination.isEmpty ? providerName.map { "\($0) root" } ?? "the folder root"
                                                    : relativeDestination
            return .wouldFile(destination: shown)
        }
    }
}
