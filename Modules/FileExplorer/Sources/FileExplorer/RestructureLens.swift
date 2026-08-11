import SwiftUI
import Design
import Sync

/// Organize ▸ Restructure: families of sibling folders that were shaped differently at different
/// times.
///
/// **Report-only, deliberately.** A finding says *these thirteen folders use four different
/// internal shapes*; it does not offer to fix them. The fix is a manifest of typed operations —
/// create, rename, move — over years of documents, and that surface has six invariants of its own
/// to satisfy before it can be safe to aim at a real tree (ROADMAP 20). Naming the disagreement is
/// the half that is useful on its own and cannot do any harm.
///
/// The three states are distinct on purpose, and none of them borrows another's words: **no
/// profile** means the detectors have nothing to read, **no findings** means they ran and the tree
/// agrees with itself, and a list means it does not.
struct RestructureLens: View {
    let findings: [StructureFinding]
    /// Findings about a folder the scope sits *inside* — see ``ScopeRelation/aboutAncestor``.
    ///
    /// **Surfaced rather than dropped, and that is a design requirement rather than a nicety.**
    /// Restructure compares sibling *families*, so under a scope pointed at a leaf the `inside`
    /// list is frequently empty — that is the honest answer, not a bug. Dropping the ancestor
    /// findings on top of it would leave the lens looking permanently broken at exactly the depth
    /// people scope to, which is one of the three reasons live-binding scope to the pane was
    /// rejected. They are kept visually subordinate: this is context about the surroundings, not
    /// work in the scope, and the rail badge deliberately does not count them.
    var aboutAncestor: [StructureFinding] = []
    let hasProfile: Bool
    /// How many folders this lens's answer covers — **nil when that is not known**.
    ///
    /// Scoped, not the whole survey. It was `profile.folders.count`, so the clean state said
    /// "Checked 3,013 folders" while the list above it had been narrowed to one subtree: a number
    /// about the tree beside an answer about a folder. Nil when there is no profile, or when the
    /// scope is a subtree the survey has never seen — in which case the sentence drops the count
    /// rather than inventing a zero.
    let folderCount: Int?
    /// Whether Organize is narrowed to a subtree — the clean state says a different thing about a
    /// folder than about the whole tree.
    var isScoped: Bool = false
    /// The provider this lens's answer covers, for the setup card's title — it compares sibling
    /// families across the surveyed tree, not inside the focused folder.
    var providerName: String?
    let accent: Color
    let onReveal: (String) -> Void
    /// Opens Settings ▸ Organize, where the survey this lens reads is set up. **The setup card's
    /// trigger, and the reason it is a route rather than a scan:** the folder profile is built
    /// from the tree once and read from disk at launch; there is no button anywhere that makes
    /// one, so a "Check structure" trigger here would be a prominent button that cannot run.
    var onOpenSurveySettings: (() -> Void)?

    private var isEmpty: Bool { findings.isEmpty && aboutAncestor.isEmpty }

    var body: some View {
        if !hasProfile {
            noProfileState
        } else if isEmpty {
            cleanState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(findings) { finding in
                        findingCard(finding)
                    }
                    if !aboutAncestor.isEmpty {
                        ancestorHeader
                        ForEach(aboutAncestor) { finding in
                            findingCard(finding).opacity(0.72)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    /// Names what the section below it is, in the words the design asked for: these findings are
    /// about the folder above the one you scoped to.
    private var ancestorHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.left.up")
                .scaledFont(.system(size: 10, weight: .semibold))
            Text(findings.isEmpty
                 ? "Nothing about this folder itself — but about the folder above it:"
                 : "About the folder above this one:")
                .scaledFont(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.top, findings.isEmpty ? 0 : 6)
    }

    private func findingCard(_ finding: StructureFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.family)
                        .scaledFont(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("\(finding.memberCount) folders, \(finding.schemes.count) internal shapes")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Reveal") { onReveal(finding.family) }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .chromeHover()
            }
            // The schemes are shown rather than asserted: the eras are visible, and so is the odd
            // year out. A verdict that only said "these disagree" would be asking to be trusted.
            ForEach(Array(finding.schemes.enumerated()), id: \.offset) { _, scheme in
                schemeRow(scheme)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The C2 recipe, not a hand-rolled slab: every other lens's content cards wear
        // lensCard(), and this was the one set outside the family — flat gray, radius 9, and
        // no lit-glass hairline in dark. The scheme rows inside keep their quiet inner fills.
        .lensCard()
    }

    /// A scheme row for the setup card's sample — `schemeRow`'s two-column shape at sample scale.
    /// Deliberately a separate body rather than a `StructureFinding.Scheme` fed through the real
    /// one: the sample is a diagram, and building a fake finding to draw it would put an invented
    /// family one type-check away from the list of real ones.
    private func sampleSchemeRow(members: String, vocabulary: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(members)
                .scaledFont(.system(size: 10.5, weight: .medium))
                .frame(width: 140, alignment: .leading)
                .lineLimit(2)
            Text(vocabulary)
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.30)))
    }

    private func schemeRow(_ scheme: StructureFinding.Scheme) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(scheme.members.joined(separator: ", "))
                .scaledFont(.system(size: 11, weight: .medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(2)
            // The vocabulary these siblings AGREE on — the intersection. A union would advertise
            // one member's stray extra as part of the convention.
            Text(scheme.vocabulary.isEmpty
                 ? "no shared subfolders"
                 : scheme.vocabulary.joined(separator: " · "))
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.30)))
    }

    private var cleanState: some View {
        EmptyStateView(icon: "checkmark.seal",
                       title: Self.cleanTitle(isScoped: isScoped),
                       message: Self.cleanMessage(folderCount: folderCount))
    }

    /// The clean state's words, as values so they can be asserted without rendering.
    ///
    /// The title changes with the subject because "the tree agrees with itself" is a claim about
    /// the whole tree, and under a scope this lens has only looked at part of it.
    static func cleanTitle(isScoped: Bool) -> String {
        isScoped ? "This folder agrees with itself" : "The tree agrees with itself"
    }

    static func cleanMessage(folderCount: Int?) -> String {
        let tail = "No family of sibling folders is using more than one internal shape."
        guard let folderCount else { return tail }
        return "Checked \(folderCount) folder\(folderCount == 1 ? "" : "s"). " + tail
    }

    /// Restructure before it has anything to read — **the setup card, like every other lens.**
    ///
    /// This was a centred `EmptyStateView`: the icon, two sentences, and no way to act on them.
    /// It is this lens's "before" screen, so it wears what the other lenses' before-screens wear
    /// — the job, the safety contract, one trigger, and sample rows in the shape real findings
    /// take. The samples matter more here than anywhere else, because a structure finding is the
    /// least self-explanatory result Organize produces: a family, a count of shapes, and one row
    /// per shape naming the subfolders that shape's members agree on.
    ///
    /// **Its trigger is a route, not a scan** (see ``onOpenSurveySettings``), and it says so —
    /// "Set up the survey", never a verb that implies this screen can produce the answer itself.
    /// With no route wired the card still stands and simply drops the button, which is the
    /// honest rendering of a lens whose input has to arrive from elsewhere.
    private var noProfileState: some View {
        LensSetupCard(
            intro: LensIntros.restructure(providerName: providerName),
            accent: accent,
            triggerTitle: "Set up the survey",
            triggerSymbol: "gearshape",
            triggerHelp: "Restructure reads the survey of your tree rather than the disk, so it "
                + "needs that survey first. Opens Settings ▸ Organize.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: "Example of the structure-finding format: a family of sibling "
                + "folders, how many of them use how many different internal shapes, and one row "
                + "per shape listing the subfolders its members agree on. These are samples, not "
                + "folders in your tree.",
            onStart: onOpenSurveySettings
        ) {
            // The real card's own shape, at sample scale: the family path, the verdict line, and
            // one row per shape — members on the left, the subfolders those members AGREE on
            // (the intersection, never a union) on the right. Drawn rather than described,
            // because "two internal shapes" means nothing until you have seen the two.
            LensSetupSampleRow {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Family/Aditi/Events")
                        .scaledFont(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("13 folders, 2 internal shapes")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                    sampleSchemeRow(members: "Naming Ceremony, Birthday",
                                    vocabulary: "Photos · Invitations")
                    sampleSchemeRow(members: "Graduation",
                                    vocabulary: "no shared subfolders")
                }
            }
        }
    }
}
