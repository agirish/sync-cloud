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
                               verb: Verb) -> StructureFinding? {
        guard let relative = relativePath(of: folder, under: root) else { return nil }
        let candidates = findings.filter { offers(verb, $0) }
        guard !candidates.isEmpty else { return nil }

        if let exact = candidates.first(where: { $0.subject == relative }) { return exact }
        // The nearest ancestor: deepest family that contains the folder. Sorting by the family's
        // length picks the closest one when a folder sits inside two nested families.
        return candidates
            .filter { RestructurePaths.isInside(relative, of: $0.subject) }
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
        return String(folder.dropFirst(root.count + 1))
    }
}
