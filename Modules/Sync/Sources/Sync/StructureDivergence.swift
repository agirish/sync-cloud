import Foundation

/// What class of disagreement a structure finding names — and therefore what acting on it would do.
///
/// One case per detector, settled as the complete set **before** any store serialises a raw value
/// (ROADMAP_V5 §5.0): `RestructureStore` keys suppressions and answers on `kind × path`, so a raw
/// value is a file-format commitment. **Raw values are append-only and never reused** — the same
/// rule `GlassLevel` follows, for the same reason.
///
/// Two cases are not like the others, deliberately:
/// - ``deadWeight`` never renders as a finding card — crowding is a property of the scope, always
///   non-zero on a real tree, and it shows as the strip's filtered counts (§5.2). The kind exists
///   anyway because the empties-removal manifest and the suppression key both need the identity.
/// - ``ask`` carries no plan at all: it is a question, and the answer is a remembered choice, not
///   an operation (§5.3). **No detector produces one in 5.0** — the case is reserved, and the
///   rules below (`carriesPlan`, the lens's glyph, symbol and verb) answer for it so that landing
///   §5.3's detector is a detector and nothing else. Grep before believing this paragraph in a
///   later release: `grep -rn "kind: \.ask" Modules/*/Sources` returns nothing today, and that
///   emptiness is what makes "reserved" true rather than aspirational.
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
    /// A disagreement no fact in the tree settles — answered, never applied.
    /// **Reserved: nothing constructs one in 5.0.** See the type's own note above.
    case ask

    /// Whether a finding of this kind can end in a plan — the rail badge counts only these,
    /// because a badge you cannot drive to zero is a badge people stop reading (§5.1).
    ///
    /// `ask` is the stated exclusion; `deadWeight` is report-only in 5.0 (its sub-class with a
    /// rule, the empties, is reached through the crowding strip rather than a card); and
    /// `looseAboveSeries` hands its per-file fix to To File rather than growing an Apply, so
    /// there is no plan here to count.
    public var carriesPlan: Bool {
        switch self {
        case .ask, .deadWeight, .looseAboveSeries: return false
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

    /// Which of two folders echoes the other — the two sub-rules of one kind (ROADMAP_V5 §5.2:
    /// count them as one kind with two sub-rules, or the card cannot say which shape it found).
    public enum EchoRelation: Equatable, Sendable {
        /// A child restating its parent's name — `PG&E/PGE`.
        case parentChild
        /// Two siblings spelling one name differently — `Form W-2` beside `Form W2`.
        case sibling
    }

    /// What a non-shape detector saw — the payload the card renders. One case per kind that
    /// carries more than its subject; ``FindingKind/shape`` keeps ``schemes`` instead, unchanged
    /// from the shipped detector.
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
    /// For ``FindingKind/shape`` this IS the family; for the others it is narrower — the echoed
    /// child, the mirrored inbox, the backlog member. **The subject, not the family, is the second
    /// half of the identity**, because `kind × family` is not unique: echo-name can fire twice in
    /// one family on two different sibling pairs, and one suppression keyed on the family would
    /// have silenced both (ROADMAP_V5 §5.0). The family is still carried for §5.2's grouping rule —
    /// a folder's rows sort together under one path heading.
    public let subject: String
    /// The schemes found, largest membership first. Non-empty only for ``FindingKind/shape``.
    public let schemes: [Scheme]

    /// Siblings whose shape no second sibling vouches for — the unvouched drop path
    /// (ROADMAP_V5 §5.1). Rendered greyed, as drift: they are members of the family, and a card
    /// that says "11 folders" about a family of 17 is undercounting on purpose it cannot state.
    public let drift: [String]

    /// Siblings with no vocabulary at all — a leaf, or one whose children are all axis values.
    /// **The folder the plan most needs to house**: it is evidence for no era, so nothing else
    /// will claim it, and *no shape of its own* is a different sentence from *disagrees with the
    /// others*.
    public let shapeless: [String]

    /// What the detector saw, for every kind whose card needs more than the subject.
    public let detail: Detail?

    /// `kind × subject` — the composite identity every store key shares (ROADMAP_V5 §5.0).
    ///
    /// The kind went into the id before the second detector landed, not after: `RestructureLens`
    /// renders one `ForEach(findings)`, and one family producing a *Shape* and a *Series* and an
    /// *Ask* is the whole point of the detector set.
    public var id: String { "\(kind.rawValue)|\(subject)" }

    /// How many siblings the finding covers — **the whole family**, both drop paths included.
    /// The card read "11 folders" on a family of 17 while 5 drifted and one had no shape at all;
    /// the subtitle counts the family, and the two dropped classes render as their own rows.
    public var memberCount: Int {
        schemes.reduce(0) { $0 + $1.members.count } + drift.count + shapeless.count
    }

    /// The one-line summary — "Finance/US/Income Tax — 17 folders, 3 schemes" for shape, the
    /// kind's own phrase for the rest. The Organize overview prints this as its example lines,
    /// and "Health/Dental/2025 — 0 folders, 0 schemes" was what a backlog finding read as when
    /// this was shape's sentence for everyone.
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
        case .ask: return "\(subject) — needs an answer"
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
/// The same recurring event — a tax year, a visa period — gets a folder each time, and each one is
/// filed sensibly *at the time*. Years later the series has four internal vocabularies and finding
/// a W-2 means first working out which era you are standing in. No per-file verdict can express
/// that, because the defect is not in any file.
///
/// ## The hard part is silence
///
/// Measured on the real profile: **247 folder names appear under more than one parent and 105 span
/// different top-level areas, and almost all of them are correct.** `Statements/`, `Reference/` and
/// `Transcripts/` are role folders that are *supposed* to recur. A detector that flags repeated
/// names produces hundreds of false positives and gets switched off in a day. Two rules keep it
/// quiet, and both were validated against that profile before this was written:
///
/// - **Axis values are not structure** (``vocabulary(of:in:)``). Children named for a year, a
///   person, a jurisdiction or an inbox are dropped before two siblings are compared: they recur
///   legitimately *and* differ legitimately. What survives is the folder's role vocabulary — the
///   part that is supposed to agree. Leaving them in flags `Chase/Archive` (accounts ran for
///   different years) and `Credit Accounts` (two of four have a backlog folder).
/// - **Difference is not divergence** (``AgreementRule``). A family diverges only when **two or
///   more groups of siblings each vouch for a different shape**. One odd sibling out of thirteen is
///   drift, not an era. Without this gate a score-based version rates `Travel/Trips/United States`
///   at 1.00, because Arizona holds Phoenix and Nevada holds Las Vegas.
///
/// Run against 2,798 folders those two rules returned **two** divergent families — `Finance/US/Income
/// Tax` and `Immigration/Authorization/H-4` — with the controls above quiet. Re-run against the
/// live 3,013-folder profile on **2026-08-16** they return **one**: the H-4 family was reorganised
/// by hand on 6 Aug and now agrees with itself, which is the outcome this detector exists to
/// produce. `Finance/US/Income Tax` reports three vouched schemes out of seventeen siblings.
/// **Keep this number current** — it is the sentence a reader calibrates the silence bar against,
/// and a stale one reads as a detector that has quietly stopped firing.
///
/// One detector is still **absent, and no longer for the original reason**: *duplicated taxonomy*
/// (two siblings with the same child names) is dominated by correct parallels — Vanguard's Roth
/// and Traditional IRAs, four Chase accounts foldered by year, every `IN`/`US` jurisdiction pair.
/// **Identical sibling structure is usually a sign of health**, and separating the real case needs
/// content overlap, not names. That evidence now exists — the duplicate scan's `.sameText` pass
/// groups documents across folders — so the detector is scheduled rather than refused
/// (ROADMAP_V5 §5.9, last of the set, because it is the only one that can be stale: it reads a
/// scan, not the profile).
public enum StructureDivergence {

    /// The agreement gate: how many groups, and how big each has to be.
    public enum AgreementRule {
        /// A family needs at least this many distinct schemes to be divergent rather than drifting.
        public static let minimumSchemes = 2
        /// Each of those schemes needs at least this many siblings vouching for it. A scheme of one
        /// is an odd folder out; two independent folders agreeing is the cheapest evidence that a
        /// *convention* existed.
        public static let minimumMembers = 2
        /// Single-linkage similarity threshold. Exact-shape matching shatters the 2016–2023 tax era
        /// into eight singletons over stray extras, so siblings cluster on overlap instead.
        public static let similarity = 0.5
    }

    /// Axis names whose values are legitimately different between siblings.
    ///
    /// Read from the profile's own `axes` rather than guessed from the name, which is what makes
    /// this survive a household that files by something this list never anticipated.
    static let axisKeys: Set<String> = ["year", "fiscalYear", "person", "jurisdiction"]

    /// Every divergent family in a profile, in path order.
    ///
    /// Builds the sibling map itself. `StructureDetectors.run` has already built one and passes it
    /// to the other detectors, so it calls the overload below rather than paying for a second.
    public static func findings(in profile: FolderProfile) -> [StructureFinding] {
        findings(in: profile, childrenByParent: families(in: profile))
    }

    /// Every divergent family in a profile, in path order, against a sibling map the caller
    /// already has.
    ///
    /// **The map is the same relation the prefix walk it replaces expressed** — see
    /// ``vocabulary(of:in:childrenByParent:)`` for the equivalence argument and the one shape of
    /// path key where they would part company.
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
        // Each sibling's role vocabulary. A sibling with no vocabulary at all — a leaf, or one
        // whose children are entirely axis values — carries no evidence either way and takes no
        // part in clustering; it is CARRIED on the finding as `shapeless` rather than silently
        // dropped, because "no shape of its own" is a fact about the family the card must state.
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
                // The scheme's vocabulary is what its members AGREE on — the intersection, not the
                // union. A union would report stray extras as part of the convention, which is the
                // same mistake exact-shape matching makes at the clustering step.
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
    /// Builds the sibling map itself, which is a full pass over the profile — use the overload
    /// below from anywhere that already holds one. This shape stays for the tests that read one
    /// folder's vocabulary in isolation.
    static func vocabulary(of path: String, in profile: FolderProfile) -> Set<String> {
        vocabulary(of: path, in: profile, childrenByParent: families(in: profile))
    }

    /// A folder's role vocabulary, against a sibling map the caller already has.
    ///
    /// **This is the whole detector sweep's cost centre.** The prefix walk this replaces scanned
    /// *every* folder in the profile once per child of every family with four or more members —
    /// O(folders²), 1.6 s of Organize's 1.9 s first-visit stall on a 5,020-folder profile. The map
    /// is built once per run and this reads one bucket.
    ///
    /// ## Why the two agree
    ///
    /// The walk selected `childPath.hasPrefix(path + "/")` with no further `/` in the remainder —
    /// the immediate-children relation. ``families(in:)`` keys on `deletingLastPathComponent`,
    /// which is that same relation for every path that has no trailing slash, no empty component
    /// and no `.` component: `deletingLastPathComponent` *normalises*, so `"A/B/"` and `"A//B"`
    /// both land in bucket `A` while the walk excluded them from `A` (their remainders contain a
    /// `/`). The `hasPrefix`/remainder test is therefore **kept** below rather than replaced by
    /// `lastPathComponent`: it costs one prefix compare per sibling and makes the new set a subset
    /// of the old one by construction, for any input.
    ///
    /// The other direction — a child the walk found that the map does not hold — needs `path`
    /// itself to carry a trailing slash (`"A/"` buckets its children under `A`, not `A/`), and
    /// that path could not be a family member in the first place: ``families(in:)`` would file
    /// `"A/"` itself under the empty parent, which it skips. Checked against the live
    /// 5,020-folder profile on 2026-09-02: zero keys with a trailing slash, a `//` or a `.`
    /// component, and the two relations agree for all 5,020 parents.
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
    /// **The test is whether the child INTRODUCED the axis value, not whether it carries one** —
    /// and getting that wrong silences the whole detector. The real profile propagates axes down a
    /// subtree: `Finance/US/Income Tax/2013/Federal Tax` carries `year: 2013` and
    /// `jurisdiction: US` exactly as its ancestors do. A "does this entry have an axis key?" test
    /// therefore drops every role folder under a year, every vocabulary comes back empty, and the
    /// detector reports nothing at all — which is what it did against the real 3,013-folder
    /// profile while twelve synthetic tests stayed green, because a fixture only puts the axis on
    /// the folder that owns it.
    ///
    /// Comparing against the parent's value is also what makes the *alias* case work without an
    /// alias map here: `Family/Mom` carries `person: Muktha` under a `Family` that carries no
    /// person axis, so it introduced one even though its name matches neither the value nor a year.
    ///
    /// The bare-year and inbox tests stay as the fallback for a profile that records no axes at
    /// all. What none of them catch is a **shadow** axis value — `IRS Docs - 2023` beside the bare
    /// years, with no `year` axis recorded — which is a detector of its own and is not claimed here.
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
    /// Single linkage — join a group if you are close enough to **any** member — rather than
    /// complete linkage, because an era grows a stray extra folder in its later years and each
    /// year is still recognisably the same scheme as the one before it. Complete linkage would
    /// split the 2016–2023 era at the first year that added a folder.
    /// **A bridging item merges the groups it bridges**, which is what makes this single linkage
    /// rather than "join the first group that will have you". It joined the first match and moved
    /// on: with A and B seeded apart and C close to both, C landed in A and B stayed its own
    /// group — two schemes reported for a family that agrees transitively, and which of them you
    /// got depended on the order the children were walked in. The finding this feeds says "these
    /// folders disagree about how they are organised", so a split that is an artefact of iteration
    /// order is a divergence the user is asked to look at and cannot see.
    static func cluster(_ items: [(name: String, words: Set<String>)])
        -> [[(name: String, words: Set<String>)]] {
        // Grouped by POSITION, so a merge can put the members back in profile order — which
        // ``StructureFinding/Scheme/members`` documents and the scheme sort's tiebreaker reads.
        // Appending merged groups end-to-end gave `[A₀, A₂, B₁, B₃, C₄]` for two alternating
        // schemes joined by a bridge: every member present, none of them in the order the survey
        // walked them.
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
