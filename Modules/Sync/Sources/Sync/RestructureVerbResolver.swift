import Foundation

/// Which Restructure verb a menu can offer for a selected folder, and which finding it would act
/// on. A menu acts on a selection and Restructure's surfaces act on a finding; this joins the two,
/// so `Plan…` and `Set up like its siblings` are reachable from the menus and the keyboard, not
/// only from the card.
public enum RestructureVerbResolver {

    /// What a menu verb wants to do with a folder.
    public enum Verb: Equatable, Sendable {
        /// Open the plan surface for the folder's finding, whichever kind carries one.
        case plan
        /// Create the folders this member's siblings expect. Only a backlog finding offers it.
        case setUp
    }

    /// What pressing a verb on a folder should do: one answer, read by both the menu's availability
    /// and the workspace that carries the press out, so the two can't disagree. An enabled item
    /// whose handler then refuses is the worst outcome, so availability is `resolve(...) == .run`.
    public enum Resolution: Equatable {
        /// Act on this finding.
        case run(StructureFinding)
        /// Don't offer the verb at all: there is nothing here it could act on.
        case unavailable
        /// The verb applies, but something outside the finding blocks it, and the user needs the
        /// sentence rather than a silently greyed item.
        case refuse(String)
    }

    /// The whole decision. `storeIsReadable` is false when `restructure.json` cannot be read.
    public static func resolve(_ verb: Verb, folder: String, root: String,
                               in findings: [StructureFinding],
                               storeIsReadable: Bool,
                               alreadyScaffolded: Set<String> = []) -> Resolution {
        // Both verbs need the store and refuse without it. A plan's first act is to save a draft; a
        // scaffold is a landing, and `restructureLandingRefusal` refuses one whose ledger record
        // can't be kept, so an enabled `.setUp` would warn and do nothing.
        if !storeIsReadable {
            return .refuse(verb == .plan
                ? "The plan store cannot be read, so a plan could not be saved — Restructure is "
                    + "read-only until that is fixed."
                : "The plan store cannot be read, so this landing could not be recorded — "
                    + "Restructure is read-only until that is fixed.")
        }
        guard let finding = finding(forFolder: folder, root: root, in: findings, verb: verb,
                                    alreadyScaffolded: alreadyScaffolded) else {
            return .unavailable
        }
        return .run(finding)
    }

    /// The finding `folder` resolves to for `verb`, or nil when the menu should stay greyed.
    ///
    /// Exact subject first, then the nearest ancestor: a selected `Income Tax/2013` means its own
    /// finding if it has one, else the family it belongs to. Anything further away is a guess, and
    /// a menu item that acts on a folder the user didn't select is worse than a greyed one.
    ///
    /// `folder` and `root` are absolute; findings are profile-relative, and this is the one place
    /// the menu converts.
    public static func finding(forFolder folder: String, root: String,
                               in findings: [StructureFinding],
                               verb: Verb,
                               alreadyScaffolded: Set<String> = []) -> StructureFinding? {
        guard let relative = relativePath(of: folder, under: root) else { return nil }
        // A scaffold that has already landed is not on offer: the card shows "Scaffolded", and an
        // enabled item would record a second landing that creates nothing.
        let candidates = findings.filter {
            offers(verb, $0) && !(verb == .setUp && alreadyScaffolded.contains($0.subject))
        }
        guard !candidates.isEmpty else { return nil }

        if let exact = candidates.first(where: { $0.subject == relative }) { return exact }
        // The ancestor fallback is for `shape` alone, whose subject is the family, so a clicked
        // member is inside it. Every other kind's subject is one folder: falling back from a child
        // would turn a selected `PG&E/PGE/2024` into a merge of `PG&E/PGE` into `PG&E`, folders the
        // user never selected.
        return candidates
            .filter { $0.kind == .shape && RestructurePaths.isInside(relative, of: $0.subject) }
            .max { $0.subject.count < $1.subject.count }
    }

    /// Whether a finding can answer this verb. `plan` follows the card's own routing, so a menu
    /// item can't offer a surface the lens would withhold; `setUp` is the scaffold, which only a
    /// backlog finding with something to create has.
    static func offers(_ verb: Verb, _ finding: StructureFinding) -> Bool {
        switch verb {
        case .plan:
            return RestructurePlanRouting.carriesPlanSurface(finding)
        case .setUp:
            guard case .backlog(let scaffold, _)? = finding.detail else { return false }
            return !scaffold.isEmpty
        }
    }

    /// An absolute path as the profile keys it, or nil when it isn't under the root. The root
    /// arrives tilde-abbreviated from the profile and absolute from the pane, so both are expanded
    /// before comparing, or `Plan…` would derive nothing on a real profile.
    static func relativePath(of folder: String, under root: String) -> String? {
        let folder = (folder as NSString).expandingTildeInPath
        let root = (root as NSString).expandingTildeInPath
        guard !folder.isEmpty, !root.isEmpty else { return nil }
        guard folder != root else { return "." }
        guard RestructurePaths.isInside(folder, of: root) else { return nil }
        // Drop the root's components, not its characters: with `root == "/"` a character count
        // would eat the name's first letter.
        let components = folder.split(separator: "/").map(String.init)
        return components.dropFirst(root.split(separator: "/").count).joined(separator: "/")
    }
}
