import Foundation

/// Which Restructure verb a menu can offer for a selected folder, and which finding it would act
/// on (ROADMAP_V5 §11; proposal O10).
///
/// §11 gave four verbs menu homes and two of them shipped without one, deferred with a dated note
/// because they need this: a menu acts on a **selection**, and Restructure's surfaces act on a
/// **finding**. Nothing joined the two, so `Plan…` and `Set up like its siblings` were reachable
/// only by finding the card and clicking it — which is exactly the reachability problem §11
/// exists to fix, and it left keyboard users with no route to a plan at all.
public enum RestructureVerbResolver {

    /// What a menu verb wants to do with a folder.
    public enum Verb: Equatable, Sendable {
        /// Open the plan surface for the folder's finding — whichever kind carries one.
        case plan
        /// Create the folders this member's siblings expect. Only a backlog finding offers it.
        case setUp
    }

    /// What pressing a verb on a folder should do — **one answer, read by both the menu's
    /// availability and the workspace that carries the press out.**
    ///
    /// They were two hand-synchronised copies, and every difference between them was a defect a
    /// user could reach: the menu offered `Plan…` on a store the card withheld it for (a draft
    /// that cannot persist breaks §5.7's survives-a-quit promise), and kept `Set Up Like Its
    /// Siblings` enabled after the scaffold had landed, minting a second ledger record that
    /// created nothing. An enabled item whose handler then refuses is the worst of the three
    /// possible behaviours, so availability IS `resolve(...) == .run`.
    public enum Resolution: Equatable {
        /// Act on this finding.
        case run(StructureFinding)
        /// Do not offer the verb at all — there is nothing here it could act on.
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
        // **Both verbs need the store, for different reasons, and both refuse without it.** A
        // plan's first act is to save a draft; a scaffold is a landing, and
        // `restructureLandingRefusal` refuses one whose ledger record could not be kept — so a
        // `.setUp` item left enabled here is an enabled item over a handler that warns and does
        // nothing, which this type's own doc calls the worst of the three behaviours.
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
    /// **Exact subject first, then the nearest ancestor.** Someone who selects
    /// `Income Tax/2013` and asks to plan means that folder's own finding if it has one; failing
    /// that, they mean the family it belongs to, because a shape finding's subject IS the family
    /// and the member they clicked is inside it. Anything further away is a guess, and a menu
    /// item that acts on a folder the user did not select is worse than a greyed one.
    ///
    /// `folder` and `root` are absolute; findings are keyed profile-relative, and this is the one
    /// place that conversion happens for the menu.
    public static func finding(forFolder folder: String, root: String,
                               in findings: [StructureFinding],
                               verb: Verb,
                               alreadyScaffolded: Set<String> = []) -> StructureFinding? {
        guard let relative = relativePath(of: folder, under: root) else { return nil }
        // A scaffold that has already landed is not on offer — the card swaps its button for
        // "Scaffolded — the survey hasn't caught up yet", and a menu item that stayed enabled
        // minted a second ledger landing that created nothing.
        let candidates = findings.filter {
            offers(verb, $0) && !(verb == .setUp && alreadyScaffolded.contains($0.subject))
        }
        guard !candidates.isEmpty else { return nil }

        if let exact = candidates.first(where: { $0.subject == relative }) { return exact }
        // **The ancestor fallback is for `shape` alone**, and that is the whole of its
        // justification: a shape finding's subject IS the family, so a member the user clicked is
        // genuinely inside it. Every other kind's subject is one specific folder — falling back to
        // one from a child meant selecting `PG&E/PGE/2024` and being offered a merge of
        // `PG&E/PGE` into `PG&E`, two folders the user selected neither directly nor as a family,
        // under a verb named "shape". A menu item that acts on a folder the user did not select is
        // worse than a greyed one, which is this function's own stated rule.
        return candidates
            .filter { $0.kind == .shape && RestructurePaths.isInside(relative, of: $0.subject) }
            .max { $0.subject.count < $1.subject.count }
    }

    /// Whether a finding can answer this verb. `plan` follows the same routing the card's own
    /// trigger does, so a menu item cannot offer a surface the lens would withhold; `setUp` is
    /// the scaffold, which only a backlog finding with something to create has.
    static func offers(_ verb: Verb, _ finding: StructureFinding) -> Bool {
        switch verb {
        case .plan:
            return RestructurePlanRouting.carriesPlanSurface(finding)
        case .setUp:
            guard case .backlog(let scaffold, _)? = finding.detail else { return false }
            return !scaffold.isEmpty
        }
    }

    /// An absolute path as the profile keys it, or nil when it is not under the root at all.
    ///
    /// The root arrives tilde-abbreviated from the profile and absolute from the pane, so both
    /// are expanded before comparing — the mismatch that made `Plan…` derive nothing on every
    /// real profile once already.
    static func relativePath(of folder: String, under root: String) -> String? {
        let folder = (folder as NSString).expandingTildeInPath
        let root = (root as NSString).expandingTildeInPath
        guard !folder.isEmpty, !root.isEmpty else { return nil }
        guard folder != root else { return "." }
        guard RestructurePaths.isInside(folder, of: root) else { return nil }
        // Drop the root's COMPONENTS rather than its characters: `root == "/"` made the character
        // form eat the first letter of the name. Unreachable from a real profile, and one line
        // cheaper than depending on that.
        let components = folder.split(separator: "/").map(String.init)
        return components.dropFirst(root.split(separator: "/").count).joined(separator: "/")
    }
}
