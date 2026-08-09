import Events
import Foundation

/// N2 Automations — rule orchestration. Loads/persists the user's rules, runs a dry-run preview
/// over a folder (what the enabled rules *would* do, nothing moved), and — after per-file
/// confirmation in the UI — files the approved matches for real as one undoable run. Everything
/// here is on-device — filename globs, UTType, file attributes, and (only when a rule asks) the
/// injected on-device snippet extractor. The cloud filing classifier is never constructed on this
/// path. Rules also steer the Organize scan's suggestions (see `FilingEngine.suggest(automations:)`).
extension FileSyncManager {

    /// Where automation rules persist (JSON, in the injectable `filingRuleDefaults` store — the same
    /// store Filing's rules use, so tests that stub defaults cover both).
    public static let automationRulesDefaultsKey = "automationRules"

    // MARK: Rule store

    /// What reading a persisted store actually found. Three outcomes, because collapsing the last
    /// two is what made a decode failure destructive: the getters treat both as "no rules", but a
    /// caller that is about to make an IRREVERSIBLE decision (the legacy migration, which sets a
    /// one-way "already migrated" flag) must be able to tell them apart and stand down.
    enum PersistedStoreRead<Value> {
        /// Read and decoded.
        case decoded(Value)
        /// Nothing saved under this key — the ordinary first-run case.
        case absent
        /// Data is present but could not be decoded. Already reported and set aside.
        case unreadable
    }

    /// Reads a persisted store, telling "nothing saved yet" apart from "saved, but unreadable".
    ///
    /// Both used to read as `[]`, and that silence was expensive: the very next edit re-encodes the
    /// now-empty array over the stored value, so a decode failure (a schema change after running an
    /// older build, a truncated plist) permanently destroyed every rule the user had taught — with
    /// nothing in the log to explain why their files had stopped filing themselves. Absent data
    /// stays quiet; undecodable data is reported once per store per session and the raw payload is
    /// set aside under a sibling key so the overwrite is no longer the end of it.
    static func readPersistedStore<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        key: String,
        describing what: String
    ) -> PersistedStoreRead<T> {
        guard let data = defaults.data(forKey: key) else { return .absent }
        if let decoded = try? JSONDecoder().decode(type, from: data) { return .decoded(decoded) }
        // Preserving is effectively ungated — no session-scoped claim, because an earlier attempt
        // keyed one on `ObjectIdentifier` and silently dropped backups (a released `UserDefaults`
        // can be reallocated at the same address, so a later store inherited an earlier one's
        // claim; it surfaced only under the full suite). The only skip is the one that cannot lose
        // anything: the backup key ALREADY holds these exact bytes.
        //
        // That skip is not cosmetic. These getters are hot — a scan reads them per file — so an
        // unconditional `set` re-wrote the whole payload to `cfprefsd` tens of thousands of times
        // per scan for as long as the store stayed corrupt, which is precisely when the disk is
        // the thing least worth hammering. A read-and-compare is cheap and keeps the invariant
        // intact: after this line the bytes are under `backupKey`, however they got there.
        let backupKey = key + ".unreadable"
        if defaults.data(forKey: backupKey) != data {
            defaults.set(data, forKey: backupKey)
        }
        // Only the REPORT is rate-limited, since these getters are read repeatedly. Keyed by the key
        // name plus the payload, so two stores holding the same key can each still be reported, and
        // a store whose corruption CHANGES is reported again.
        if corruptStoreKeysWarned.claim("\(key)\u{0}\(data.hashValue)") {
            Logger.shared.error(
                "Saved \(what) could not be read (\(data.count) bytes) and will be treated as empty — "
                + "the unreadable copy was kept under \"\(backupKey)\"")
        }
        return .unreadable
    }

    /// Writes a persisted store, KEEPING the previously saved bytes when the value cannot be
    /// encoded.
    ///
    /// The setters used to spell this `defaults.set(try? JSONEncoder().encode(newValue), forKey:)`,
    /// and `UserDefaults.set(nil, forKey:)` is defined as `removeObject(forKey:)` — so a failed
    /// encode did not skip the write, it DELETED every rule the user had taught. That is the same
    /// destruction `readPersistedStore` above goes to real lengths to prevent on the way in (an
    /// undecodable payload is preserved under a sibling key rather than silently becoming `[]`),
    /// arriving through the one door that was left open.
    ///
    /// These models are `String`/`Int`/`Bool`/`UUID` throughout, so `JSONEncoder` should never
    /// actually fail — which is the point: a wipe that cannot be triggered on purpose is a wipe
    /// nobody would find the cause of. Failing closed costs one unsaved edit and a log line;
    /// failing open costs the whole store with no way back.
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

    /// The decoded value, or nil for both "nothing saved" and "unreadable" — the shape the getters
    /// want, since neither can do anything but show an empty list.
    static func decodePersistedStore<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        key: String,
        describing what: String
    ) -> T? {
        if case .decoded(let value) = readPersistedStore(type, from: defaults, key: key, describing: what) {
            return value
        }
        return nil
    }

    /// One-shot-per-store gate for the report above, so a hot getter cannot log per read.
    /// Lock-guarded rather than actor-isolated: cheap, and it keeps the gate independent of where
    /// a future caller reads from.
    private static let corruptStoreKeysWarned = OneShotKeySet()

    /// The persisted rules, decoded from defaults. A corrupt/absent value decodes to `[]`.
    private var persistedAutomationRules: [AutomationRule] {
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

    /// Adds a new rule (or replaces one with the same id) and persists. Logged — a rule is durable,
    /// user-auditable state (it silently files matching files on every run), so its creation/edit
    /// belongs in the activity log alongside the filing moves it will drive.
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

    /// Enables/disables a rule (kept, not deleted) and persists. A no-op when the stored value
    /// already matches: today the card's Toggle only fires on a real flip, but this method is the
    /// public seam any future caller (CLI, sync-from-elsewhere) would use, and a value-unchanged
    /// call must not re-persist or write a duplicate "enabled/disabled" line to the audit log.
    public func setAutomationRule(id: UUID, enabled: Bool) {
        ensureAutomationRulesLoaded()
        guard let idx = automationRules.firstIndex(where: { $0.id == id }) else { return }
        guard automationRules[idx].enabled != enabled else { return }
        automationRules[idx].enabled = enabled
        persistedAutomationRules = automationRules
        Logger.shared.info("Automation rule \(enabled ? "enabled" : "disabled"): “\(automationRules[idx].name)”")
    }

    // MARK: Dry run

    /// Starts a cancellable dry-run preview of the enabled rules over `root`, replacing any in-flight
    /// one. `root` is the folder whose loose files are scanned; `destinationRoot` is the anchor a
    /// rule's (provider-relative) destination template resolves against — the **provider root**, not
    /// the scanned folder, so previewing while focused into a subfolder still files into the same
    /// place. `providerName` labels the surface and resolves the `{provider}` token.
    /// `only` scopes the preview to a single rule (its id); nil previews all enabled, runnable rules.
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
        // A rule with an ABSOLUTE destination (a learned/migrated rule) that points outside this
        // provider is inert here — filtered up front so it can't claim a file another rule would
        // handle. Compared on raw paths, the same strings the legacy provider scoping compared.
        let anchorPath = destinationAnchor.path
        func isInert(_ rule: AutomationRule) -> Bool {
            rule.destinationTemplate.hasPrefix("/")
                && AutomationEvaluator.absoluteDestination(rule.destinationTemplate, providerRoot: anchorPath) == nil
        }
        // Previewing exactly one provider-inert rule must SAY so — a silent empty report reads as
        // "the conditions match nothing", which is the wrong diagnosis.
        if let only, let rule = automationRules.first(where: { $0.id == only }), isInert(rule) {
            let name = rule.name.isEmpty ? "This rule" : "“\(rule.name)”"
            banner = .warning("\(name) files into a folder outside \(providerName ?? "this provider"), so it can't act here.")
            Logger.shared.info("Automations preview skipped: rule “\(rule.name)” is scoped to \(rule.destinationTemplate), outside \(anchorPath)")
            return
        }
        let inertCount = automationRules.filter { $0.isRunnable && $0.enabled && isInert($0) }.count
        if only == nil, inertCount > 0 {
            Logger.shared.info("Automations preview: \(inertCount) rule(s) scoped to another provider were skipped")
        }
        let rules = automationRules.filter { rule in
            guard rule.isRunnable, !isInert(rule) else { return false }
            return only == nil ? rule.enabled : rule.id == only
        }

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

        // Read once, outside the loop: the roster does not change mid-preview, and resolving it
        // per file would ask the manager for it a few hundred times.
        let registry = filingPersonRegistry
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
            ).attributing(registry)

            // Read the file's on-device text only when content could still CHANGE a rule's outcome
            // for this file: some content-reading rule doesn't match yet but could once its content
            // conditions are known. A rule already satisfied by the name alone (a `mentions` rule
            // whose words are all in the filename) skips the extraction entirely.
            if readsContents, let extractor = snippetExtractor,
               rules.contains(where: { $0.requiresContent
                   && !AutomationEvaluator.matches($0, facts, now: now)
                   && AutomationEvaluator.couldMatchPendingContent($0, facts, now: now) }) {
                facts.snippet = (await extractor(file.id))?.lowercased()
                // Tokenize the excerpt so `mentionsAll` sees the same canonical content tokens the
                // Organize scan matches with.
                if let snippet = facts.snippet { facts.contentTokens = FilingEngine.nameTokens(snippet) }
                // Re-resolved now the page is in hand: a scan whose NAME names nobody can still be
                // attributed by what it says, which is the whole reason the precedence rule falls
                // through to the page rather than stopping at the filename.
                facts = facts.attributing(registry)
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
        // The report carries its own root string, so the lifecycle's `root` stays nil here —
        // only the completion flag is published.
        self.hasRunAutomationDryRun = true
        Logger.shared.info("Automations dry run: \(root.lastPathComponent) — \(looseFiles.count) file(s), "
            + "\(report.wouldFileCount) would file, \(report.needsAttentionCount) need a look "
            + "(a preview — nothing moved yet)")
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
        case .resolved(let resolvedDestination):
            // An absolute destination (a migrated F3 rule) names its folder directly; a relative one
            // anchors at the provider root. Provider-inert absolute rules were filtered out before
            // matching, so an absolute path here is inside this provider.
            let destinationDir = resolvedDestination.hasPrefix("/")
                ? URL(fileURLWithPath: resolvedDestination).standardizedFileURL
                : destinationRoot.appendingPathComponent(resolvedDestination).standardizedFileURL
            let currentParent = URL(fileURLWithPath: facts.parentPath).standardizedFileURL
            // Label with the provider-relative form whenever the destination sits under the root
            // (boundary-safe strip; a destination outside the root keeps its absolute path).
            let rootPath = destinationRoot.standardizedFileURL.path
            let relativeDestination = PathBoundary.relativize(destinationDir.path, under: rootPath)
                ?? destinationDir.path
            let label = relativeDestination.isEmpty ? (providerName.map { "\($0) root" } ?? "the folder root")
                                                    : relativeDestination
            // Case-folded per the volume, matching `performFiling`'s no-op test: the preview must
            // not promise a move that the apply path will (correctly) decline, and before this the
            // apply path did not decline it — it renamed the file in place.
            if PathBoundary.namesSameDirectory(
                destinationDir.path,
                currentParent.path,
                caseSensitive: FileSyncManager.volumeSupportsCaseSensitiveNames(for: currentParent)
            ) {
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
            ? .warning("Filed \(n) file\(n == 1 ? "" : "s"); \(failures) couldn't be filed. Press ⌘Z to undo", undoable: true)
            : .success("Filed \(n) file\(n == 1 ? "" : "s"). Press ⌘Z to undo", undoable: true)
        return (n, failures)
    }
}

/// A set of keys that each admit exactly one claim, for "warn once per session" gates.
/// Lock-guarded because the callers are nonisolated computed properties reached from any thread.
final class OneShotKeySet: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed: Set<String> = []

    /// True the FIRST time `key` is claimed, false every time after.
    func claim(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed.insert(key).inserted
    }
}
