import Foundation

/// What class of disagreement a structure finding names — and therefore what acting on it would do.
///
/// One case per detector (ROADMAP v5 §5.0). `RestructureStore` keys suppressions and answers on
/// `kind × path`, so a raw value is a file-format commitment: **raw values are append-only and
/// never reused**, as with `GlassLevel`.
///
/// ``deadWeight`` differs on purpose: it never renders as a card, because crowding shows as the
/// strip's counts (§5.2). The kind exists because the empties-removal manifest and the suppression
/// key need the identity.
public enum FindingKind: String, CaseIterable, Codable, Sendable {
    /// Sibling folders shaped differently at different times — the shipped detector.
    case shape
    /// The newest instance of a recurring series has no folders yet.
    case backlog
    /// A year-bearing name beside bare-year siblings (`IRS Docs - 2023` beside `2023`).
    case shadowAxis
    /// Two names for one thing — a child echoing its parent, or two siblings echoing each other.
    case echoName
    /// An inbox path shadowing a real destination (`Health/TODO/Dental` beside `Health/Dental`).
    case mirroredInbox
    /// Pass-through folders, single-file leaves and wholly empty folders — the crowding strip.
    case deadWeight
    /// Files parked in the parent of a year run that has folders for them.
    case looseAboveSeries
    /// A loose folder beside the container it belongs in (`Home/ATT Bill` beside `Home/ATT/`).
    case looseBesideContainer
    /// Two folders holding the same documents under parallel taxonomies (§5.9, needs a scan).
    case duplicatedTaxonomy

    /// Whether a finding of this kind can end in a plan. The rail badge counts only these: a badge
    /// you can't drive to zero stops being read (§5.1). `deadWeight` is report-only (the empties are reached through the crowding strip); `looseAboveSeries` hands
    /// its per-file fix to To File.
    public var carriesPlan: Bool {
        switch self {
        case .deadWeight, .looseAboveSeries: return false
        case .shape, .backlog, .shadowAxis, .echoName, .mirroredInbox,
             .looseBesideContainer, .duplicatedTaxonomy: return true
        }
    }
}

/// One place where a tree disagrees with its own habits.
///
/// Report-only. A finding names the family and the schemes it found; it does **not** carry a plan,
/// because a plan is a manifest of typed operations and that is a separate, destructive surface
/// (ROADMAP 20). Nothing here moves, renames or deletes anything.
public struct StructureFinding: Equatable, Identifiable, Sendable {

    /// One internal shape, and the siblings that use it.
    public struct Scheme: Equatable, Sendable {
        /// The vocabulary these siblings agree on, sorted for a stable reading order.
        public let vocabulary: [String]
        /// The sibling folder names using it, in profile order.
        public let members: [String]

        public init(vocabulary: [String], members: [String]) {
            self.vocabulary = vocabulary
            self.members = members
        }
    }

    /// Which of two folders echoes the other: one kind's two sub-rules, so the card can say which
    /// shape it found (ROADMAP v5 §5.2).
    public enum EchoRelation: Equatable, Sendable {
        /// A child restating its parent's name — `PG&E/PGE`.
        case parentChild
        /// Two siblings spelling one name differently — `Form W-2` beside `Form W2`.
        case sibling
    }

    /// What a non-shape detector saw — the payload the card renders. One case per kind that
    /// carries more than its subject; ``FindingKind/shape`` uses ``schemes`` instead.
    public enum Detail: Equatable, Sendable {
        /// The newest member of a year run holds files and no folders; `scaffold` is the vouched
        /// vocabulary the family expects, minus what the member already has.
        case backlog(scaffold: [String], looseFiles: Int)
        /// A year-bearing name beside bare-year siblings; `target` is the bare year it shadows,
        /// which exists as a sibling (a merge) or does not (a rename).
        case shadowAxis(target: String, targetExists: Bool)
        /// The subject echoes `counterpart` — its parent, or a sibling.
        case echoName(counterpart: String, relation: EchoRelation)
        /// The subject sits inside an inbox and mirrors `destination`, the same path with the
        /// inbox component removed.
        case mirroredInbox(destination: String)
        /// The subject holds `looseFiles` files above `seriesFolders` year folders.
        case looseAboveSeries(looseFiles: Int, seriesFolders: Int)
        /// The subject's name restates `container`, a sibling that should hold it.
        case looseBesideContainer(container: String)
        /// The subject and `counterpart` hold the same documents under parallel taxonomies —
        /// `matchedDocuments` distinct same-text pairs span the two (§5.9, the one detector that
        /// reads the duplicate scan rather than the profile).
        case duplicatedTaxonomy(counterpart: String, matchedDocuments: Int)
    }

    /// Which detector produced this, and therefore what acting on it would do.
    public let kind: FindingKind
    /// The parent whose children disagree, relative to the profile root.
    public let family: String
    /// The most specific folder the finding is about, relative to the profile root.
    ///
    /// For ``FindingKind/shape`` this is the family; for the others it is narrower (the echoed
    /// child, the mirrored inbox, the backlog member). The subject, not the family, is the second
    /// half of the identity: echo-name can fire twice in one family, and a suppression keyed on the
    /// family would silence both (ROADMAP v5 §5.0). The family stays for §5.2's grouping.
    public let subject: String
    /// The schemes found, largest membership first. Non-empty only for ``FindingKind/shape``.
    public let schemes: [Scheme]

    /// Siblings whose shape no second sibling vouches for (ROADMAP v5 §5.1). Rendered greyed, as
    /// drift: they are still members of the family, and the card counts them.
    public let drift: [String]

    /// Siblings with no vocabulary at all: a leaf, or one whose children are all axis values. The
    /// folder the plan most needs to house, since no era claims it; "no shape of its own" is a
    /// different sentence from "disagrees with the others".
    public let shapeless: [String]

    /// What the detector saw, for every kind whose card needs more than the subject.
    public let detail: Detail?

    /// `kind × subject` — the composite identity every store key shares (ROADMAP v5 §5.0). The
    /// kind is in it because `RestructureLens` renders one `ForEach(findings)`, and one folder can
    /// carry findings of several kinds.
    public var id: String { "\(kind.rawValue)|\(subject)" }

    /// How many siblings the finding covers: the whole family, drift and shapeless included, so the
    /// subtitle doesn't undercount. The two dropped classes render as their own rows.
    public var memberCount: Int {
        schemes.reduce(0) { $0 + $1.members.count } + drift.count + shapeless.count
    }

    /// The one-line summary — "Finance/US/Income Tax — 17 folders, 3 schemes" for shape, the
    /// kind's own phrase for the rest. The Organize overview prints these as its example lines.
    public var headline: String {
        switch kind {
        case .shape:
            return "\(family) — \(memberCount) folders, \(schemes.count) schemes"
        case .backlog: return "\(subject) — no folders yet"
        case .shadowAxis: return "\(subject) — a year in the name"
        case .echoName: return "\(subject) — two names for one thing"
        case .mirroredInbox: return "\(subject) — mirrors a real folder"
        case .deadWeight: return "\(subject) — dead weight"
        case .looseAboveSeries: return "\(subject) — files above the year run"
        case .looseBesideContainer: return "\(subject) — beside its container"
        case .duplicatedTaxonomy: return "\(subject) — duplicated taxonomy"
        }
    }

    public init(kind: FindingKind = .shape, family: String, subject: String? = nil,
                schemes: [Scheme] = [], drift: [String] = [], shapeless: [String] = [],
                detail: Detail? = nil) {
        self.kind = kind
        self.family = family
        self.subject = subject ?? family
        self.schemes = schemes
        self.drift = drift
        self.shapeless = shapeless
        self.detail = detail
    }
}

/// Finds families of sibling folders that were shaped differently at different times.
///
/// A recurring event (a tax year, a visa period) gets a folder each time, each filed sensibly at
/// the time. Years later the series has several internal vocabularies, and finding a W-2 means
/// first working out which era you are in. No per-file verdict can say that: the defect is in no
/// file.
///
/// ## The hard part is silence
///
/// On the real profile hundreds of folder names recur under different parents, and almost all are
/// correct: `Statements/`, `Reference/` and `Transcripts/` are role folders meant to recur. A
/// detector that flags repeated names gets switched off in a day. Two rules keep it quiet:
///
/// - Axis values are not structure (``vocabulary(of:in:)``). Children named for a year, a
///   person, a jurisdiction or an inbox are dropped before siblings are compared: they recur and
///   differ legitimately. What survives is the role vocabulary, the part meant to agree. Left in,
///   they would flag `Chase/Archive` (accounts ran for different years).
/// - Difference is not divergence (``AgreementRule``). A family diverges only when two or more
///   groups of siblings each vouch for a different shape; one odd sibling out is drift. Without
///   this gate `Travel/Trips/United States` would score high, since Arizona holds Phoenix and
///   Nevada holds Las Vegas.
///
/// On the reference profile the two rules leave one divergent family, `Finance/US/Income Tax`,
/// with three vouched schemes out of seventeen siblings, and the controls above quiet.
///
/// Duplicated taxonomy is not detected here: same child names are usually a sign of health
/// (Vanguard's two IRAs, Chase accounts foldered by year), and the real case needs content overlap.
/// ``StructureDuplicatedTaxonomy`` reads that from the duplicate scan (ROADMAP v5 §5.9).
public enum StructureDivergence {

    /// The agreement gate: how many groups, and how big each has to be.
    public enum AgreementRule {
        /// A family needs at least this many distinct schemes to be divergent rather than drifting.
        public static let minimumSchemes = 2
        /// Each of those schemes needs at least this many siblings vouching for it. A scheme of one
        /// is an odd folder out; two folders agreeing is the least evidence of a convention.
        public static let minimumMembers = 2
        /// Single-linkage similarity threshold. Exact-shape matching would shatter one era into
        /// singletons over stray extras, so siblings cluster on overlap instead.
        public static let similarity = 0.5
    }

    /// Axis names whose values are legitimately different between siblings.
    ///
    /// Read from the profile's own `axes` rather than guessed from names, so it holds for a
    /// household that files by something unexpected.
    static let axisKeys: Set<String> = ["year", "fiscalYear", "person", "jurisdiction"]

    /// Every divergent family in a profile, in path order.
    ///
    /// Builds the sibling map itself; `StructureDetectors.run` already has one and calls the
    /// overload below.
    public static func findings(in profile: FolderProfile) -> [StructureFinding] {
        findings(in: profile, childrenByParent: families(in: profile))
    }

    /// Every divergent family in a profile, in path order, against a sibling map the caller
    /// already has.
    ///
    /// See ``vocabulary(of:in:childrenByParent:)`` for how the map relates to the paths.
    public static func findings(in profile: FolderProfile,
                                childrenByParent: [String: [String]]) -> [StructureFinding] {
        childrenByParent
            .sorted { $0.key < $1.key }
            .compactMap { finding(family: $0.key, children: $0.value, in: profile,
                                  childrenByParent: childrenByParent) }
    }

    /// Parent path → its immediate children, both relative to the profile root.
    static func families(in profile: FolderProfile) -> [String: [String]] {
        var byParent: [String: [String]] = [:]
        for path in profile.folders.keys {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty else { continue }
            byParent[parent, default: []].append(path)
        }
        return byParent.mapValues { $0.sorted() }
    }

    /// One family's verdict, or `nil` when it agrees with itself.
    static func finding(family: String, children: [String],
                        in profile: FolderProfile,
                        childrenByParent: [String: [String]]) -> StructureFinding? {
        // A family needs enough members for two groups of two to be possible at all.
        guard children.count >= AgreementRule.minimumSchemes * AgreementRule.minimumMembers else {
            return nil
        }
        // Each sibling's role vocabulary. A sibling with none carries no evidence and isn't
        // clustered, but it is kept as `shapeless`: the card must state it.
        var shapeless: [String] = []
        let vocabularies = children.reduce(into: [(name: String, words: Set<String>)]()) { acc, child in
            let words = vocabulary(of: child, in: profile, childrenByParent: childrenByParent)
            let name = (child as NSString).lastPathComponent
            guard !words.isEmpty else {
                shapeless.append(name)
                return
            }
            acc.append((name: name, words: words))
        }
        guard vocabularies.count >= AgreementRule.minimumSchemes * AgreementRule.minimumMembers else {
            return nil
        }

        let groups = cluster(vocabularies)
        let vouched = groups.filter { $0.count >= AgreementRule.minimumMembers }
        guard vouched.count >= AgreementRule.minimumSchemes else { return nil }

        let schemes = vouched
            .map { group -> StructureFinding.Scheme in
                // The scheme's vocabulary is what its members agree on, the intersection: a union
                // would report stray extras as part of the convention.
                let shared = group.dropFirst().reduce(group[0].words) { $0.intersection($1.words) }
                return StructureFinding.Scheme(vocabulary: shared.sorted(),
                                               members: group.map(\.name))
            }
            .sorted { ($0.members.count, $0.members.first ?? "") > ($1.members.count, $1.members.first ?? "") }
        // The unvouched drop path, kept as drift: a scheme of one is an odd folder out, not an
        // era, but it is still a member of the family the subtitle counts.
        let drift = groups.filter { $0.count < AgreementRule.minimumMembers }
            .flatMap { $0.map(\.name) }
            .sorted()
        return StructureFinding(family: family, schemes: schemes, drift: drift,
                                shapeless: shapeless.sorted())
    }

    /// A folder's role vocabulary: its children's names, with the axis-valued ones dropped.
    ///
    /// Builds the sibling map itself, a full pass over the profile: use the overload below when you
    /// hold one. Kept for tests that read one folder's vocabulary in isolation.
    static func vocabulary(of path: String, in profile: FolderProfile) -> Set<String> {
        vocabulary(of: path, in: profile, childrenByParent: families(in: profile))
    }

    /// A folder's role vocabulary, against a sibling map the caller already has.
    ///
    /// The detector sweep's cost centre, so it reads one bucket of a map built once per run; a walk
    /// of every folder per child is O(folders²).
    ///
    /// The `hasPrefix`/remainder test stays even though the map already buckets by parent:
    /// `deletingLastPathComponent` normalises, so `"A/B/"` and `"A//B"` land in bucket `A`, and the
    /// test keeps only true immediate children for any input. Real profile keys have no trailing
    /// slash, `//` or `.` component.
    static func vocabulary(of path: String, in profile: FolderProfile,
                           childrenByParent: [String: [String]]) -> Set<String> {
        var words: Set<String> = []
        let prefix = path + "/"
        let parent = profile.folders[path]
        for childPath in childrenByParent[path] ?? [] {
            guard childPath.hasPrefix(prefix) else { continue }
            let relative = String(childPath.dropFirst(prefix.count))
            // Immediate children only — a grandchild is the *child's* vocabulary, not this one's.
            guard !relative.isEmpty, !relative.contains("/") else { continue }
            guard let entry = profile.folders[childPath] else { continue }
            guard !isAxisValued(path: childPath, name: relative, entry: entry, parent: parent) else {
                continue
            }
            words.insert(relative.lowercased())
        }
        return words
    }

    /// Whether a child is an axis value rather than a role.
    ///
    /// **The test is whether the child introduced the axis value, not whether it carries one.**
    /// Real profiles propagate axes down a subtree (`…/2013/Federal Tax` carries `year: 2013` like
    /// its ancestors), so a "has an axis key?" test would drop every role folder under a year,
    /// empty every vocabulary and silence the detector. Fixtures that put the axis only on its
    /// owner can't show this.
    ///
    /// Comparing with the parent also covers aliases: `Family/Mom` carries `person: Granny` under a
    /// `Family` with no person axis, so it introduced one though its name matches neither.
    ///
    /// The bare-year and inbox tests are the fallback for a profile with no axes. A shadow axis
    /// value (`IRS Docs - 2023` beside bare years) is ``StructureShadowAxis``'s job, not this one's.
    static func isAxisValued(path: String, name: String, entry: FolderProfileEntry,
                             parent: FolderProfileEntry?) -> Bool {
        for key in axisKeys {
            guard let value = entry.axes[key] else { continue }
            // Inherited: the parent already stood in this same axis value, so the child is not
            // naming it — it is sitting inside it.
            if parent?.axes[key] == value { continue }
            return true
        }
        if isBareYear(name) { return true }
        if FolderProfile.isInboxPath(path) { return true }
        return false
    }

    /// A four-digit year, which is an axis value whether or not the profile says so.
    static func isBareYear(_ name: String) -> Bool {
        guard name.count == 4, name.allSatisfy(\.isNumber), let year = Int(name) else { return false }
        return (1900...2200).contains(year)
    }

    /// Single-linkage clustering on Jaccard overlap.
    ///
    /// Single linkage (join a group if close enough to any member), not complete linkage: an era
    /// grows stray extra folders over the years while each year still resembles the one before,
    /// and complete linkage would split it at the first addition.
    ///
    /// A bridging item merges the groups it bridges: joining only the first match would leave
    /// a family that agrees transitively split in two depending on walk order, reporting a
    /// divergence the user can't see.
    static func cluster(_ items: [(name: String, words: Set<String>)])
        -> [[(name: String, words: Set<String>)]] {
        // Grouped by position, so a merge can put members back in profile order, which
        // ``StructureFinding/Scheme/members`` documents and the scheme sort's tiebreaker reads.
        var groups: [[Int]] = []
        for (index, item) in items.enumerated() {
            let bridged = groups.indices.filter { i in
                groups[i].contains { jaccard(items[$0].words, item.words) >= AgreementRule.similarity }
            }
            guard let home = bridged.first else {
                groups.append([index])
                continue
            }
            // Highest index first, so removing does not shift the ones still to be moved.
            for other in bridged.dropFirst().reversed() {
                groups[home].append(contentsOf: groups[other])
                groups.remove(at: other)
            }
            groups[home].append(index)
        }
        return groups.map { members in members.sorted().map { items[$0] } }
    }

    /// Overlap over union. Two empty sets never reach here — an empty vocabulary is dropped before
    /// clustering, because "agrees with nothing" is not the same as "agrees with everything".
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
