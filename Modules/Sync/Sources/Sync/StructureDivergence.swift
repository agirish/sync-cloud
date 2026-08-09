import Foundation

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

    /// The parent whose children disagree, relative to the profile root.
    public let family: String
    /// The schemes found, largest membership first.
    public let schemes: [Scheme]

    public var id: String { family }

    /// How many siblings the finding covers.
    public var memberCount: Int { schemes.reduce(0) { $0 + $1.members.count } }

    /// The one-line summary — "Finance/US/Income Tax — 13 years, 4 schemes".
    public var headline: String {
        "\(family) — \(memberCount) folders, \(schemes.count) schemes"
    }

    public init(family: String, schemes: [Scheme]) {
        self.family = family
        self.schemes = schemes
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
/// Run against 2,798 folders those two rules return **two** divergent families — `Finance/US/Income
/// Tax` (13 years, 4 eras) and `Immigration/Authorization/H-4` — with the controls above quiet.
///
/// One detector is deliberately **absent**: *duplicated taxonomy* (two siblings with the same child
/// names) is dominated by correct parallels — Vanguard's Roth and Traditional IRAs, four Chase
/// accounts foldered by year, every `IN`/`US` jurisdiction pair. **Identical sibling structure is
/// usually a sign of health**, and separating the real case needs content overlap, not names.
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
    public static func findings(in profile: FolderProfile) -> [StructureFinding] {
        families(in: profile)
            .sorted { $0.key < $1.key }
            .compactMap { finding(family: $0.key, children: $0.value, in: profile) }
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
                        in profile: FolderProfile) -> StructureFinding? {
        // A family needs enough members for two groups of two to be possible at all.
        guard children.count >= AgreementRule.minimumSchemes * AgreementRule.minimumMembers else {
            return nil
        }
        // Each sibling's role vocabulary. A sibling with no vocabulary at all — a leaf, or one
        // whose children are entirely axis values — carries no evidence either way and is dropped
        // rather than counted as "disagreeing with everyone".
        let vocabularies = children.reduce(into: [(name: String, words: Set<String>)]()) { acc, child in
            let words = vocabulary(of: child, in: profile)
            guard !words.isEmpty else { return }
            acc.append((name: (child as NSString).lastPathComponent, words: words))
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
        return StructureFinding(family: family, schemes: schemes)
    }

    /// A folder's role vocabulary: its children's names, with the axis-valued ones dropped.
    static func vocabulary(of path: String, in profile: FolderProfile) -> Set<String> {
        var words: Set<String> = []
        let prefix = path + "/"
        let parent = profile.folders[path]
        for (childPath, entry) in profile.folders where childPath.hasPrefix(prefix) {
            let relative = String(childPath.dropFirst(prefix.count))
            // Immediate children only — a grandchild is the *child's* vocabulary, not this one's.
            guard !relative.contains("/") else { continue }
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
    static func cluster(_ items: [(name: String, words: Set<String>)])
        -> [[(name: String, words: Set<String>)]] {
        var groups: [[(name: String, words: Set<String>)]] = []
        for item in items {
            if let index = groups.firstIndex(where: { group in
                group.contains { jaccard($0.words, item.words) >= AgreementRule.similarity }
            }) {
                groups[index].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups
    }

    /// Overlap over union. Two empty sets never reach here — an empty vocabulary is dropped before
    /// clustering, because "agrees with nothing" is not the same as "agrees with everything".
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
