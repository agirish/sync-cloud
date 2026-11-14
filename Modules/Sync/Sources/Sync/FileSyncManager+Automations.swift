import Events
import Foundation

/// The one owner of "which automation rules may act".
///
/// Four surfaces run the same match → resolve-destination → file pipeline: the Organize scan's
/// suggestion steering (`FilingEngine.automationCandidates`), its content-gating pre-pass, the
/// Automations dry-run preview, and the rule proposer's already-covered check. Eligibility is
/// decided here once so they can't drift apart. The one exception to "enabled", testing a rule
/// before enabling it, has to name itself: ``testing(_:in:)``.
public struct AutomationRuleSet: Sendable {
    /// The rules allowed to act, in the user's order.
    public let rules: [AutomationRule]

    private init(_ rules: [AutomationRule]) { self.rules = rules }

    /// The shared bar: enabled and runnable. Runnable (a name, a destination, conditions the
    /// evaluator can prove; ``AutomationRule/isRunnable``) keeps a half-built rule inert
    /// everywhere; enabled is the user's own switch.
    public static func eligible(_ all: [AutomationRule]) -> AutomationRuleSet {
        AutomationRuleSet(all.filter { $0.enabled && $0.isRunnable })
    }

    /// The escape hatch for previewing a disabled rule: exactly the rule with `id`, enabled or
    /// not. Still runnable only, since a rule the evaluator can't prove has no outcome to preview.
    public static func testing(_ id: UUID, in all: [AutomationRule]) -> AutomationRuleSet {
        AutomationRuleSet(all.filter { $0.isRunnable && $0.id == id })
    }

    /// A caller-specific narrowing that can only *remove* rules (the dry run drops rules whose
    /// absolute destination lies outside the previewed provider). It cannot widen eligibility.
    public func narrowed(to isIncluded: (AutomationRule) -> Bool) -> AutomationRuleSet {
        AutomationRuleSet(rules.filter(isIncluded))
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Whether any acting rule reads file text at all — the cheap check that gates building the
    /// snippet extractor pass in the first place.
    public var readsContent: Bool { rules.contains { $0.requiresContent } }

    /// Whether reading this file's text could still flip some acting rule's outcome: the per-file
    /// gate on the expensive text extraction. The Organize scan and the Automations preview share
    /// it so a rule gives one answer on both. Each pass passes its own fixed `now`.
    public func contentCouldStillDecide(_ facts: AutomationFileFacts, now: Date) -> Bool {
        rules.contains { rule in
            guard rule.requiresContent, AutomationEvaluator.couldMatchPendingContent(rule, facts, now: now) else { return false }
            // A rule that already matches by name still needs the text when page 1 names its folder.
            return rule.destinationReadsContent || !AutomationEvaluator.matches(rule, facts, now: now)
        }
    }

    /// The first acting rule, in user order, whose conditions match.
    public func firstMatch(for facts: AutomationFileFacts, now: Date) -> AutomationRule? {
        rules.first { AutomationEvaluator.matches($0, facts, now: now) }
    }
}

/// Automations: loads and saves the user's rules, previews what the enabled rules would do in a
/// folder (nothing moved), and, after per-file confirmation in the UI, files the approved matches
/// as one undoable run. All on-device: filename globs, UTType, file attributes and, only when a
/// rule asks, the injected snippet extractor. The cloud filing classifier is never built here.
/// Rules also steer the Organize scan's suggestions (`FilingEngine.suggest(automations:)`).
extension FileSyncManager {

    /// Where automation rules persist: JSON in the injectable `filingRuleDefaults` store, the one
    /// Filing's rules use, so tests that stub defaults cover both.
    public nonisolated static let automationRulesDefaultsKey = "automationRules"

    // MARK: Rule store

    /// The decoded value, or nil for both "nothing saved" and "unreadable": the getters can only
    /// show an empty list either way. Undecodable data (a schema change, a truncated plist) would
    /// then be saved over by the next edit, losing every rule the user taught, so it is reported
    /// once per store per session and the raw bytes are kept under a sibling key. Absent data
    /// stays quiet.
    static func decodePersistedStore<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        key: String,
        describing what: String
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let decoded = try? JSONDecoder().decode(type, from: data) { return decoded }
        // Preserving is ungated by any session claim: a claim keyed on `ObjectIdentifier` would
        // drop backups, since a released `UserDefaults` can be reallocated at the same address.
        // The only skip is when the backup key already holds these exact bytes. That skip matters:
        // a scan reads these getters per file, and an unconditional `set` would rewrite the payload
        // to `cfprefsd` tens of thousands of times per scan while the store stays corrupt.
        let backupKey = key + ".unreadable"
        if defaults.data(forKey: backupKey) != data {
            defaults.set(data, forKey: backupKey)
        }
        // Only the report is rate-limited. Keyed by key name plus payload, so two stores with the
        // same key are each reported, and a store whose corruption changes is reported again.
        if corruptStoreKeysWarned.claim("\(key)\u{0}\(data.hashValue)") {
            Logger.shared.error(
                "Saved \(what) could not be read (\(data.count) bytes) and will be treated as empty — "
                + "the unreadable copy was kept under \"\(backupKey)\"")
        }
        return nil
    }

    /// Writes a persisted store, keeping the previously saved bytes when the value can't be
    /// encoded. **Never** pass `try? encode(…)` to `set`: `UserDefaults.set(nil, forKey:)` removes
    /// the key, so a failed encode would delete every rule. Encoding these models shouldn't fail,
    /// but failing closed costs one unsaved edit; failing open costs the whole store.
    static func writePersistedStore<T: Encodable>(
        _ value: T,
        to defaults: UserDefaults,
        key: String,
        describing what: String
    ) {
        guard let data = try? JSONEncoder().encode(value) else {
            Logger.shared.error(
                "Saved \(what) could not be encoded, so this change was NOT saved — the previously "
                + "saved copy is untouched under \"\(key)\"")
            return
        }
        defaults.set(data, forKey: key)
    }

    /// Once-per-store gate for the report above, so a hot getter can't log per read. Lock-guarded
    /// rather than actor-isolated, so it works wherever a caller reads from.
    private static let corruptStoreKeysWarned = OneShotKeySet()

    /// The persisted rules, decoded from defaults. A corrupt/absent value decodes to `[]`.
    var persistedAutomationRules: [AutomationRule] {
        get {
            FileSyncManager.decodePersistedStore([AutomationRule].self, from: filingRuleDefaults,
                                                 key: Self.automationRulesDefaultsKey,
                                                 describing: "automation rules") ?? []
        }
        set {
            FileSyncManager.writePersistedStore(newValue, to: filingRuleDefaults,
                                                key: Self.automationRulesDefaultsKey,
                                                describing: "automation rules")
        }
    }

    /// Loads rules from defaults into the published array exactly once. Safe to call repeatedly
    /// (the lens calls it on appear); the guard means an early empty read can't clobber later state.
    public func ensureAutomationRulesLoaded() {
        guard !didLoadAutomationRules else { return }
        didLoadAutomationRules = true
        automationRules = persistedAutomationRules
    }

    /// Adds a new rule (or replaces one with the same id) and persists. Logged, since a rule files
    /// matching files on every run and belongs in the activity log beside the moves it drives.
    public func upsertAutomationRule(_ rule: AutomationRule) {
        ensureAutomationRulesLoaded()
        let isNew = !automationRules.contains(where: { $0.id == rule.id })
        if let idx = automationRules.firstIndex(where: { $0.id == rule.id }) {
            automationRules[idx] = rule
        } else {
            automationRules.append(rule)
        }
        persistedAutomationRules = automationRules
        Logger.shared.info("Automation rule \(isNew ? "created" : "updated"): “\(rule.name)” → \(rule.destinationTemplate)")
    }

    /// Removes a rule and persists.
    public func removeAutomationRule(id: UUID) {
        ensureAutomationRulesLoaded()
        let removed = automationRules.first(where: { $0.id == id })
        automationRules.removeAll { $0.id == id }
        persistedAutomationRules = automationRules
        if let removed { Logger.shared.info("Automation rule deleted: “\(removed.name)”") }
    }

    /// Enables or disables a rule (kept, not deleted) and persists. A no-op when the value already
    /// matches, so no caller can re-persist or log a duplicate "enabled/disabled" line.
    public func setAutomationRule(id: UUID, enabled: Bool) {
        ensureAutomationRulesLoaded()
        guard let idx = automationRules.firstIndex(where: { $0.id == id }) else { return }
        guard automationRules[idx].enabled != enabled else { return }
        automationRules[idx].enabled = enabled
        persistedAutomationRules = automationRules
        Logger.shared.info("Automation rule \(enabled ? "enabled" : "disabled"): “\(automationRules[idx].name)”")
    }

    // MARK: Dry run

    /// Starts a cancellable dry-run preview over `root`'s loose files, replacing any in flight.
    /// `destinationRoot` is the provider root a rule's relative destination resolves against, not
    /// the scanned folder, so previewing from a subfolder files to the same place. `providerName`
    /// labels the surface and fills `{provider}`. `only` previews one rule; nil, all eligible ones.
    public func startAutomationDryRun(root: URL, destinationRoot: URL, providerName: String?, only: UUID? = nil) {
        automationDryRunTask = restartedScanTask(replacing: automationDryRunTask) { [weak self] in
            await self?.runAutomationDryRun(root: root, destinationRoot: destinationRoot,
                                            providerName: providerName, only: only)
        }
    }

    /// Cancels a running preview; the previous report (if any) is left intact.
    public func cancelAutomationDryRun() {
        automationDryRunTask?.cancel()
    }

    /// Clears the current preview, on provider switch, so one provider's report can't show under
    /// another.
    public func clearAutomationDryRun() {
        automationDryRunTask?.cancel()
        automationDryRun = nil
        automationDryRunLifecycle.hasCompleted = false
    }

    /// Walks `root`'s loose files, evaluates the rules on-device, and publishes the report. Text is
    /// read only for files a content condition could still decide.
    func runAutomationDryRun(
        root: URL,
        destinationRoot: URL? = nil,
        providerName: String?,
        only: UUID? = nil,
        fileManager fm: FileManaging? = nil,
        now: Date = Date()
    ) async {
        guard !automationDryRunLifecycle.isRunning else { return }
        ensureAutomationRulesLoaded()
        let fileManager = fm ?? self.fileManager
        // Destinations resolve against the provider root; with none given (tests on a temp dir),
        // against the scanned folder.
        let destinationAnchor = destinationRoot ?? root
        // A rule with an absolute destination (learned or migrated) outside this provider is inert
        // here, filtered up front so it can't claim a file another rule would handle. Compared on
        // raw paths.
        let anchorPath = destinationAnchor.path
        // So is a rule taught for another survey's tree.
        func isInert(_ rule: AutomationRule) -> Bool {
            (rule.destinationTemplate.hasPrefix("/")
                && AutomationEvaluator.absoluteDestination(rule.destinationTemplate, providerRoot: anchorPath) == nil)
                || !rule.acts(in: anchorPath)
        }
        // Previewing one inert rule must say so: a silent empty report reads as "the conditions
        // match nothing".
        if let only, let rule = automationRules.first(where: { $0.id == only }), isInert(rule) {
            let name = rule.name.isEmpty ? "This rule" : "“\(rule.name)”"
            banner = .refusal("\(name) files into a folder outside \(providerName ?? "this provider"), so it can’t act here.", log: .warn)
            Logger.shared.info("Rules preview skipped: rule “\(rule.name)” is scoped to \(rule.destinationTemplate), outside \(anchorPath)")
            return
        }
        let inertCount = AutomationRuleSet.eligible(automationRules).rules.filter(isInert).count
        if only == nil, inertCount > 0 {
            Logger.shared.info("Rules preview: \(inertCount) rule(s) scoped to another provider were skipped")
        }
        // `testing` is the deliberate escape hatch: a single-rule preview runs a rule that is
        // toggled off, so it can be tried before enabling it.
        let ruleSet = (only.map { AutomationRuleSet.testing($0, in: automationRules) }
                        ?? AutomationRuleSet.eligible(automationRules))
            .narrowed { !isInert($0) }

        beginScan(\.automationDryRunLifecycle, status: "Previewing \(root.lastPathComponent)…")
        defer {
            endScan(\.automationDryRunLifecycle)
        }

        // Loose files = the direct files in the folder (not its subfolders), mirroring Filing.
        let looseTree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager, maxDepth: 1)
        let looseFiles = looseTree.filter { !$0.isDirectory && !FilingOptions.defaultIgnoredNames.contains($0.name) }
        if Task.isCancelled { return }

        let readsContents = filingReadsContents
        let snippetExtractor = filingSnippetExtractor
        let parentFolderName = root.lastPathComponent
        let parentPath = root.path

        // Read once: the roster doesn't change mid-preview.
        let registry = filingPersonRegistry
        let identity = filingPersonIdentity
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
            ).attributing(registry, identity: identity)

            // Read the text only when it could still change a rule's outcome. A rule the name
            // already satisfies (a `mentions` rule whose words are all in the filename) skips it.
            if readsContents, let extractor = snippetExtractor,
               ruleSet.contentCouldStillDecide(facts, now: now) {
                facts.snippet = (await extractor(file.id))?.lowercased()
                // Tokenize the excerpt so `mentionsAll` sees the same canonical content tokens the
                // Organize scan matches with.
                if let snippet = facts.snippet { facts.contentTokens = FilingEngine.nameTokens(snippet) }
                // Re-attributed now the page is in hand: a scan whose name names nobody can still
                // be attributed by what it says.
                facts = facts.attributing(registry, identity: identity)
                if Task.isCancelled { return }
            }

            // First rule, in user order, that matches. `ruleSet` is already scoped, so don't
            // re-filter on `enabled` here: a preview of a disabled rule would match nothing.
            guard let rule = ruleSet.firstMatch(for: facts, now: now) else { continue }
            let resolution = Self.dryRunVerdict(
                for: rule, facts: facts, destinationRoot: destinationAnchor,
                providerName: providerName, now: now, fileManager: fileManager
            )
            rows.append(AutomationDryRunRow(
                id: file.id, fileName: file.name,
                ruleID: rule.id, ruleName: rule.name, verdict: resolution.verdict,
                destinationDir: resolution.destinationDir, destinationLabel: resolution.label,
                destinationAnchor: destinationAnchor,
                // One stat per file, so the apply can tell this file from whatever holds its path
                // later. Read through `snapshot`, not the walked metadata: the field's note says
                // why both reads must use the same API.
                sourceIdentity: ItemIdentity.snapshot(at: URL(fileURLWithPath: file.id),
                                                      fileManager: fileManager)
            ))
        }

        let report = AutomationDryRunReport(
            root: root.path, providerName: providerName,
            filesScanned: looseFiles.count, rows: rows
        )
        self.automationDryRun = report
        // The report carries its own root, so only the lifecycle's completion flag is published.
        self.automationDryRunLifecycle.hasCompleted = true
        Logger.shared.info("Rules preview: \(root.lastPathComponent) — \(looseFiles.count) file(s), "
            + "\(report.wouldFileCount) would file, \(report.needsAttentionCount) need a look "
            + "(a preview — nothing moved yet)")
    }

    /// Turns a resolved destination into a preview verdict, adding the two outcomes the pure
    /// evaluator can't know: "already there" and a name collision. `nonisolated static` so it can
    /// run off the main actor with the injected file manager.
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
            return (.needsAttention("needs \(token), which this file doesn’t have"), nil, nil)
        case .resolved(var resolvedDestination):
            // A month folder already there in another spelling is the one used.
            if !resolvedDestination.hasPrefix("/") {
                resolvedDestination = AutomationTravelDate.adoptingExistingMonth(
                    resolvedDestination, template: rule.destinationTemplate) { parent in
                        let dir = parent.isEmpty ? destinationRoot : destinationRoot.appendingPathComponent(parent)
                        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    }
            }
            // An absolute destination (a migrated rule) names its folder directly; a relative one
            // anchors at the provider root. Inert rules were filtered out, so an absolute path here
            // is inside this provider.
            let destinationDir = resolvedDestination.hasPrefix("/")
                ? URL(fileURLWithPath: resolvedDestination).standardizedFileURL
                : destinationRoot.appendingPathComponent(resolvedDestination).standardizedFileURL
            let currentParent = URL(fileURLWithPath: facts.parentPath).standardizedFileURL
            // Label with the provider-relative path when under the root, else the absolute one.
            let rootPath = destinationRoot.standardizedFileURL.path
            let relativeDestination = PathBoundary.relativize(destinationDir.path, under: rootPath)
                ?? destinationDir.path
            let label = relativeDestination.isEmpty ? (providerName.map { "\($0) root" } ?? "the folder root")
                                                    : relativeDestination
            // Case-folded per the volume and resolved through links, matching `performFiling`'s
            // no-op test, so the preview never promises a move the apply would decline.
            if PathBoundary.resolvesToSameDirectory(
                destinationDir.path,
                currentParent.path,
                caseSensitive: FileSyncManager.volumeSupportsCaseSensitiveNames(for: currentParent)
            ) {
                return (.alreadyThere, nil, nil)
            }
            let target = destinationDir.appendingPathComponent(facts.name)
            if fileManager.fileExists(atPath: target.path) {
                // Still filable (the move keeps both); flagged so the review card can say so.
                return (.needsAttention("a file named “\(facts.name)” is already there"), destinationDir, label)
            }
            return (.wouldFile(destination: label), destinationDir, label)
        }
    }

    // MARK: Filing (phase B — moves real files, one reversible run)

    /// Files the approved preview rows for real: each row with a `destinationDir` is moved there by
    /// the app's safe primitives, creating folders and never overwriting (a clash keeps both).
    /// One undo action covers the run, and every move goes to Sync History. The UI confirms each
    /// file before this is called. Returns the number filed and the number that failed.
    @discardableResult
    public func applyAutomationFiling(rows: [AutomationDryRunRow]) async -> (filed: Int, failed: Int) {
        // Don't move files Verify All may be checksumming (same guard Filing uses).
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before filing", log: .info)
            return (0, 0)
        }
        let fm = fileManager
        let logger = Logger.shared
        let actionable = rows.filter { $0.destinationDir != nil }
        guard !actionable.isEmpty else { return (0, 0) }

        var moves: [MoveItemState] = []
        var records: [SyncHistoryRecord] = []
        var filedPaths: Set<String> = []
        // Each file, where it landed and which rule sent it, for the log (`FilingBatchLog`).
        var filed: [FilingBatchLog.Filed] = []
        var failures = 0
        var rootUnavailable = 0
        var refusedChanged = 0
        let runId = UUID()

        for row in actionable {
            guard let destFolder = row.destinationDir else { continue }
            let src = URL(fileURLWithPath: row.id)
            let name = row.fileName
            let anchor = row.destinationAnchor
            let outcome: AutomationMoveOutcome = await enqueueFileOperation {
                do {
                    guard fm.fileExists(atPath: src.path) else { return .failed(rootUnavailable: false) }
                    // It must still be the file the preview matched. The report is stepped through
                    // minutes after it is taken, and a file that has since taken this path would
                    // be moved into a folder chosen for another document. A row with no recorded
                    // identity (not previewed by this process) skips the check.
                    if let recorded = row.sourceIdentity {
                        let verdict = recorded.drift(at: src, fileManager: fm)
                        guard verdict == .unchanged else {
                            throw FileOperationError.sourceChangedSincePreview
                        }
                    }
                    // Check the provider root before any I/O, as `performFiling` does.
                    // `createDirectory(withIntermediateDirectories:)` builds the whole path, so an
                    // unmounted provider would be recreated as a plain local folder and the file
                    // moved into a tree nothing syncs. Only the root is checked: everything below
                    // it is the rule's to create.
                    guard fm.fileExists(atPath: anchor.path) else {
                        throw FileOperationError.destinationRootUnavailable
                    }
                    try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                    var dst = destFolder.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)   // keep both
                    }
                    let overwritten = try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: fm)
                    return .moved(to: dst, overwritten: overwritten)
                } catch FileOperationError.sourceChangedSincePreview {
                    // Not phrased as a failure: nothing is wrong with the disk, and "failed" would
                    // send the user looking for a permissions problem. The file stays put.
                    logger.warning("Automation filing: REFUSED to move “\(name)” — it changed since "
                                   + "the preview, so it is no longer the file that rule matched; "
                                   + "leaving it in place at \(src.path)")
                    return .refusedChanged
                } catch {
                    logger.warning("Automation filing: moving “\(name)” into \(destFolder.lastPathComponent) failed: \(error.localizedDescription)")
                    return .failed(rootUnavailable: (error as? FileOperationError) == .destinationRootUnavailable)
                }
            }
            switch outcome {
            case .moved(let moved, let overwritten):
                moves.append((from: src, to: moved, overwritten: overwritten))
                let size = ((try? fm.attributesOfItem(atPath: moved.path))?[.size] as? NSNumber)?.intValue
                records.append(SyncHistoryRecord(
                    runId: runId, action: .move, sourcePath: src.path, destPath: moved.path,
                    sizeBytes: size, checksum: nil, backupPath: overwritten?.path, direction: nil
                ))
                filedPaths.insert(row.id)
                filed.append(FilingBatchLog.Filed(fileName: name, landedAs: moved.lastPathComponent,
                                                  folder: moved.deletingLastPathComponent().path,
                                                  source: "rule “\(row.ruleName)”"))
            case .failed(let wasRootUnavailable):
                failures += 1
                if wasRootUnavailable { rootUnavailable += 1 }
            case .refusedChanged:
                // Counted apart from `failures`: it isn't an error, and "N failed" would mislead a
                // user whose disk is fine.
                refusedChanged += 1
            }
        }

        // Said in both banner branches below: an unannounced refusal just shows a smaller count,
        // which reads as "there was less to do".
        let changedNote = refusedChanged == 0 ? ""
            : " \(refusedChanged) changed since the preview and \(refusedChanged == 1 ? "was" : "were") left in place."

        guard !moves.isEmpty else {
            if failures > 0 || refusedChanged > 0 {
                // A vanished provider is something the user can fix (reconnect, preview again), so
                // it is named rather than folded into the generic count.
                let couldnt = failures > 0
                    ? "Couldn’t file \(failures) file\(failures == 1 ? "" : "s")."
                    : "Nothing was filed."
                banner = rootUnavailable > 0
                    ? .warning(couldnt + " "
                               + FileOperationError.destinationRootUnavailable.localizedDescription
                               + changedNote, log: .warn)
                    : .warning(couldnt + changedNote, log: .warn)
            }
            return (0, failures)
        }
        // One undo action reverts the whole run, so ⌘Z is honest.
        registerMoveUndo(items: moves, actionName: "File \(CountedNoun.phrase(moves.count, "File")) by Automation",
                         fileManager: fm)
        let recordedRun = recordSyncHistory(records)
        // Counted apart on the filing scorecard: a rule offers one folder, so nothing to keep or change.
        filingScorecard.append(moves.map { FilingScorecard.ruleRecord(landedFile: $0.to.path, root: nil) })

        // Drop the filed rows from the current preview: their files have moved.
        if let report = automationDryRun {
            let remaining = report.rows.filter { !filedPaths.contains($0.id) }
            if remaining.isEmpty {
                automationDryRun = nil
                automationDryRunLifecycle.hasCompleted = false
            } else {
                automationDryRun = AutomationDryRunReport(root: report.root, providerName: report.providerName,
                                                          filesScanned: report.filesScanned, rows: remaining)
            }
        }

        let n = moves.count
        let summary = "Automation filing: filed \(n) file(s)\(failures > 0 ? ", \(failures) failed" : "")"
            + (refusedChanged > 0 ? ", \(refusedChanged) refused as changed since the preview" : "")
        for line in FilingBatchLog.lines(operation: "Automation filing", filed: filed, summary: summary) {
            logger.info(line)
        }
        banner = failures > 0 || refusedChanged > 0
            ? .warning("Filed \(n) file\(n == 1 ? "" : "s")."
                       + (failures > 0 ? " \(failures) couldn’t be filed." : "")
                       + (rootUnavailable > 0 ? " " + FileOperationError.destinationRootUnavailable.localizedDescription : "")
                       + changedNote, undoable: true, log: .warn).reporting(run: recordedRun)
            : .success("Filed \(n) file\(n == 1 ? "" : "s")", undoable: true).reporting(run: recordedRun)
        return (n, failures)
    }
}

/// What one enqueued automation move did. An enum, as ``FilingMoveOutcome`` is, so a move can't
/// report a destination and a failure at once.
private enum AutomationMoveOutcome: Sendable {
    case moved(to: URL, overwritten: URL?)
    /// `rootUnavailable` marks the one failure the user can act on, a provider that is gone, so
    /// the banner can name it.
    case failed(rootUnavailable: Bool)
    /// Not moved: the file at that path is no longer the one the preview matched. Not a `failed`,
    /// which would report a disk problem for the guard doing its job.
    case refusedChanged
}

/// A set of keys that each admit exactly one claim, for "warn once per session" gates.
/// Lock-guarded because the callers are nonisolated computed properties reached from any thread.
final class OneShotKeySet: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed: Set<String> = []

    /// True the first time `key` is claimed, false every time after.
    func claim(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed.insert(key).inserted
    }
}
