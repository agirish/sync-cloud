import Events
import Foundation

/// Rules taught in Ask Claude's chat (TE286): the offer built from a correction, its save, and the
/// rules answering filing help as they answer To File.
extension FileSyncManager {

    /// The first saved rule that files `path` inside the survey at `root`, as filing help's answer:
    /// High, or Medium when page 1 would name the month and wasn't read. Nil when none does, or it
    /// files into a hidden folder.
    func ruleAnswer(_ path: String, snippet: String?, root: String, profile: FolderProfile,
                    isHidden: (String) -> Bool) -> FilingHelpAnswer.Suggestion? {
        ensureAutomationRulesLoaded()
        let rules = AutomationRuleSet.eligible(automationRules).narrowed { $0.acts(in: root) }
        guard !rules.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let facts = AutomationFileFacts(
            path: path, name: name, parentFolderName: (parent as NSString).lastPathComponent, parentPath: parent,
            sizeBytes: (attributes?[.size] as? Int) ?? 0, modificationDate: attributes?[.modificationDate] as? Date,
            isDirectory: false, snippet: snippet?.lowercased(),
            contentTokens: snippet.map { FilingEngine.nameTokens($0) } ?? [])
            .attributing(filingPersonRegistry, identity: filingPersonIdentity)
        let now = Date()
        let folders = Array(profile.folders.keys)
        for rule in rules.rules where AutomationEvaluator.matches(rule, facts, now: now) {
            guard let placed = FilingEngine.ruleDestination(
                    rule, facts: facts, providerRoot: root, providerName: nil, now: now,
                    children: { parent in Self.childNames(of: parent, in: folders) }),
                  let relative = Self.relative(placed.path, toRoot: root), !relative.isEmpty,
                  !isHidden(placed.path) else { continue }
            let label = rule.name.trimmingCharacters(in: .whitespaces).isEmpty ? rule.summary : rule.name
            let missing = profile.folders[relative] == nil && !FileManager.default.fileExists(atPath: placed.path)
            var reason = "Your rule “\(label)” files this here"
            if placed.needsPage {
                reason += snippet == nil ? "; page 1 wasn’t read, so the year and month aren’t known"
                                         : "; page 1 names no date, so the year and month aren’t known"
            }
            if missing { reason += " (a new folder)" }
            return FilingHelpAnswer.Suggestion(folder: placed.path, relativePath: relative,
                                               confidence: placed.needsPage ? .medium : .high,
                                               reason: reason, evidenceToken: nil)
        }
        return nil
    }

    /// A folder's subfolder names among the survey's folders, `parent` relative.
    nonisolated static func childNames(of parent: String, in folders: [String]) -> [String] {
        folders.compactMap { folder in
            let rest: Substring
            if parent.isEmpty { rest = Substring(folder) }
            else if folder.hasPrefix(parent + "/") { rest = folder.dropFirst(parent.count + 1) }
            else { return nil }
            return rest.isEmpty || rest.contains("/") ? nil : String(rest)
        }
    }

    /// The rule a correction teaches (TE286): `path` goes into `folder` (absolute, inside the
    /// survey that covers it), and `phrases` are the words of its kind. Nothing is saved.
    /// `.failure(nil)` when the folder isn't in a survey.
    ///
    /// The rule is that survey's: its folder is relative to the survey's root, so it carries that
    /// root and acts only in that tree's scans — a ticket rule taught for iCloud's Travel never
    /// files a Dropbox ticket into Dropbox/Travel. Only rules that act there are weighed against it.
    public func ruleFromCorrection(_ path: String, into folder: String, name: String, phrases: [String],
                                   also: [String], pageSample: String?) -> Result<AutomationRuleProposer.Correction, AutomationRuleProposer.CorrectionRefusal>? {
        guard let survey = filingHelpSurvey(for: folder),
              let relative = Self.relative(folder, toRoot: survey.root), !relative.isEmpty else { return nil }
        ensureAutomationRulesLoaded()
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return AutomationRuleProposer.correction(
            fileName: (path as NSString).lastPathComponent, destinationRelativePath: relative, name: name,
            phrases: phrases, also: also, pageSample: pageSample, modificationDate: modified,
            existingRules: automationRules.filter { $0.acts(in: survey.root) })
        .map { (correction: AutomationRuleProposer.Correction) -> AutomationRuleProposer.Correction in
            // Words added to a rule keep the rule's own scope; a new rule or a sibling takes this one.
            if case .addWords = correction.kind { return correction }
            var rule = correction.rule
            rule.surveyRoot = survey.root
            return .init(kind: correction.kind, rule: rule, example: correction.example, checkedDate: correction.checkedDate)
        }
    }

    /// Saves a correction's rule on his click: a new rule at the end, words added in place, a
    /// sibling just before the rule it stands beside, so it is tried first for the files it matches.
    public func saveCorrectionRule(_ correction: AutomationRuleProposer.Correction) {
        ensureAutomationRulesLoaded()
        switch correction.kind {
        case .new:
            upsertAutomationRule(correction.rule)
        case .addWords(let added):
            // Into the rule as it is now: it may have been edited since the card was offered.
            guard var current = automationRules.first(where: { $0.id == correction.rule.id }) else {
                upsertAutomationRule(correction.rule)
                return
            }
            current.conditions = current.conditions.map { condition in
                guard case .mentionsAny(let words) = condition else { return condition }
                return .mentionsAny(words + added.filter { !words.contains($0) })
            }
            upsertAutomationRule(current)
        case .sibling(let of, _):
            guard !automationRules.contains(where: { $0.id == correction.rule.id }) else {
                upsertAutomationRule(correction.rule)
                return
            }
            let at = automationRules.firstIndex(where: { $0.id == of }) ?? automationRules.endIndex
            automationRules.insert(correction.rule, at: at)
            persistedAutomationRules = automationRules
            Logger.shared.info("Automation rule created: “\(correction.rule.name)” → \(correction.rule.destinationTemplate), before the rule it stands beside")
        }
    }
}
