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
    /// Whether the user has opened this answer **this launch** — see
    /// ``FileSyncManager/hasReviewedStructure``. False puts the setup card in front of a result
    /// that already exists, which is the whole point: it is read off a survey that may be weeks
    /// old, and the card is where that gets said.
    ///
    /// **No default**, unlike the other optional inputs here. A defaulted `true` is a gate that
    /// switches itself off for any call site that forgets the argument, and nothing would fail —
    /// which is the whole failure mode this flag exists to prevent. The compiler is a better
    /// guard than a comment.
    let hasReviewed: Bool
    /// Reveals the findings — the setup card's trigger once there is a survey to read.
    var onReview: (() -> Void)?
    /// Re-derives the folder memory from the tree as it stands now. The card's *secondary*
    /// action: the primary only reveals what is already computed, so this is the one that makes
    /// the answer more current. nil on a machine with nothing to re-survey.
    var onUpdateSurvey: (() -> Void)?

    private var isEmpty: Bool { findings.isEmpty && aboutAncestor.isEmpty }

    var body: some View {
        if !hasProfile {
            noProfileState
        } else if !hasReviewed {
            readyState
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
            Text(Self.ancestorHeading(hasFindingsHere: !findings.isEmpty))
                .scaledFont(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.top, findings.isEmpty ? 0 : 6)
    }

    /// The ancestor section's heading, as a value so it can be asserted without an accessibility
    /// tree — the same reason `cleanTitle`/`cleanMessage` are static.
    ///
    /// The two forms are not decoration. With nothing found inside the scope the list would
    /// otherwise open straight onto findings about a *different* folder, which reads as the lens
    /// having answered the question it was asked; the first form says outright that it did not.
    static func ancestorHeading(hasFindingsHere: Bool) -> String {
        hasFindingsHere
            ? "About the folder above this one:"
            : "Nothing about this folder itself — but about the folder above it:"
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
        // Grouped, like the setup card's footnote one state over: the real tree is 3,013 folders
        // and "3013" in running prose is a number the eye has to stop and parse.
        return "Checked \(folderCount.formatted()) folder\(folderCount == 1 ? "" : "s"). " + tail
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
    /// **It has no trigger, and that is the honest rendering.** The first draft put a prominent
    /// "Set up the survey" button here, routed at Settings ▸ Organize — which is where the state
    /// this replaced told people to go, and which **has no survey control on it**: an inbox path,
    /// a kept-names list, and pointers to two other tabs. The folder profile is an artifact built
    /// against the tree and read from disk at launch; no screen in the app makes one. A big blue
    /// button landing on a page with nothing to do is worse than no button, and worse than the
    /// sentence it was promoted from, because a button is a promise. So the card states where the
    /// answer would come from and stops — `LensSetupCard` draws without a trigger for exactly
    /// this.
    private var noProfileState: some View {
        LensSetupCard(
            intro: LensIntros.restructure(providerName: providerName),
            accent: accent,
            triggerTitle: "Set up the survey",
            triggerSymbol: "gearshape",
            // These three are REQUIRED by `LensSetupCard` and, with `onStart: nil` below, are
            // never rendered — the card draws its trigger, and that trigger's `.help`, only
            // inside `if let onStart`. Kept true anyway: this one used to end "Opens Settings ▸
            // Organize", which names a real tab (`SettingsTab.filing` is shown as "Organize") and
            // is exactly the promise the paragraph above says was withdrawn — that tab has no
            // survey control, and no screen in the app builds a survey at all. Copy nothing
            // renders is copy nothing checks, so it stays stale silently and becomes wrong AND
            // visible the moment somebody wires a trigger here.
            triggerHelp: "Restructure reads the survey of your tree rather than the disk, so it "
                + "needs that survey first.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: samplesAccessibility,
            onStart: nil,
            footnote: AnyView(noSurveyNote),
            samples: { samples }
        )
    }

    /// Why there is nothing to press. Sits in the same slot the reveal card puts its "read from a
    /// survey of N folders" line in — a fact about the input, under the card.
    @ViewBuilder
    private var noSurveyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").scaledFont(.system(size: 10))
            Text(Self.noSurveyNoteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// **Says what is missing, and does not say where to get it.** The state this replaced ended
    /// "Settings ▸ Organize sets it up", which was not true then either — see ``noProfileState``.
    /// Naming a destination that cannot help is the part worth not repeating.
    static let noSurveyNoteText =
        "This tree has no folder survey yet, so there is nothing to compare. "
        + "Organize's other lenses read the disk directly and work without one."

    /// Restructure with a survey to read, **before the user has asked for the answer this
    /// launch** — the same card, over results that already exist.
    ///
    /// This is the state the other lenses get for nothing. Their findings live only in memory, so
    /// a relaunch puts them back on the card by itself; Restructure's are derived from a profile
    /// read off disk during startup, so without this it was the one lens that opened straight
    /// onto an answer nobody had asked for. See ``FileSyncManager/hasReviewedStructure``.
    ///
    /// **The trigger reveals rather than computes, and the wording never pretends otherwise.**
    /// There is nothing to run: the findings are already in hand, and the click is free. What
    /// costs something — and what makes the answer current — is the re-survey, so that is the
    /// secondary button rather than the primary. Saying "Rescan" on the primary here would
    /// promise a fresh look at the disk and deliver a cached one.
    ///
    /// The footnote is where "these are cached" is actually said, in the slot To File uses for
    /// what its last cloud pass cost — a fact about work already done, under the card rather than
    /// in front of it.
    private var readyState: some View {
        LensSetupCard(
            intro: LensIntros.restructure(providerName: providerName),
            accent: accent,
            triggerTitle: Self.revealTitle(findingCount: findings.count),
            triggerSymbol: findings.isEmpty ? "checkmark.circle" : "list.bullet.rectangle",
            triggerHelp: findings.isEmpty
                ? "Show what the survey says about this tree's folder shapes. Already computed — nothing is read from disk."
                : "Show the families the survey found disagreeing. Already computed — nothing is read from disk.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: samplesAccessibility,
            onStart: onReview,
            secondary: onUpdateSurvey.map {
                LensSetupCard.SecondaryAction(
                    title: "Update the survey",
                    symbol: "arrow.clockwise",
                    help: "Re-read the tree and rebuild the folder memory these findings come "
                        + "from. Slower, and the only thing here that makes the answer current.",
                    action: $0)
            },
            footnote: AnyView(surveyNote),
            samples: { samples }
        )
    }

    /// The reveal trigger's words. **A count, because the badge beside it carries one** — a
    /// button reading "Show findings" next to a rail badge reading 12 invites the question of
    /// whether they are the same twelve, and the badge counts exactly this: `findings`, never the
    /// ancestor list (which is context about the surroundings, not work in the scope).
    ///
    /// Zero is its own phrasing rather than "Show 0 findings", which reads as a button that does
    /// nothing. What it opens is usually the clean state — but not always, because a scope with
    /// no findings of its own can still have ancestor ones, and those do render. "Check the
    /// shapes" is deliberately the one wording that is true of both.
    static func revealTitle(findingCount: Int) -> String {
        guard findingCount > 0 else { return "Check the shapes" }
        return "Show \(findingCount) finding\(findingCount == 1 ? "" : "s")"
    }

    /// Says where the answer came from, so "update" is a choice rather than a guess.
    ///
    /// **It claims coverage, never freshness.** The survey's own artifacts carry a generated
    /// stamp, but it is rewritten only when a re-survey actually changes something — so a tree
    /// that has not moved in a month has a stamp from whenever it last did, and "surveyed 3 days
    /// ago" would be a date about the last change rather than the last look. The folder count is
    /// a fact this view actually holds.
    ///
    /// **And the count is what this ANSWER covers, not how big the survey is.** `folderCount` is
    /// scoped (see its own doc), so under a narrowing it is 79 where the survey is 3,013 — and
    /// the first draft read "Read from a survey of 79 folders", which attaches the scoped number
    /// to the artifact and describes neither. That is the same too-wide/too-narrow slip
    /// ``cleanMessage`` was already fixed for one state over, which is why it says "Checked N"
    /// rather than naming the survey. This says "Covers N" for the same reason.
    @ViewBuilder
    private var surveyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").scaledFont(.system(size: 10))
            Text(Self.surveyNoteText(folderCount: folderCount))
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    static func surveyNoteText(folderCount: Int?) -> String {
        let tail = "Read from the folder survey, not from your disk. Update it if the tree has changed since."
        guard let folderCount else { return tail }
        return "Covers \(folderCount.formatted()) folder\(folderCount == 1 ? "" : "s"). " + tail
    }

    private var samplesAccessibility: String {
        "Example of the structure-finding format: a family of sibling folders, how many of them "
        + "use how many different internal shapes, and one row per shape listing the subfolders "
        + "its members agree on. These are samples, not folders in your tree."
    }

    /// The sample finding both card states show — the real card's own shape at sample scale: the
    /// family path, the verdict line, and one row per shape with members on the left and the
    /// subfolders those members AGREE on (the intersection, never a union) on the right. Drawn
    /// rather than described, because "two internal shapes" means nothing until you have seen
    /// the two.
    ///
    /// One definition, not one per state: two copies of a diagram that exists to teach one layout
    /// is how the diagram starts disagreeing with itself.
    private var samples: some View {
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
