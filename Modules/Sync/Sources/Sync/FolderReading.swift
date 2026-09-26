import Foundation

/// What a folder's profile entry says, in words.
///
/// **The Structure screen is the only place the app shows a person its own reading of their tree
/// back to them, and it has to be readable without the vocabulary.** `pass-through`, `year-bucket`
/// and `anchors` are the profile's terms; "holds folders only", "a year" and "files go here" are
/// the same facts in the user's. Nothing here decides anything — every reading is a restatement of
/// an entry ``FolderSurveyBuilder`` already produced, so a wrong reading is a wrong sentence and
/// never a wrong profile.
///
/// Lives in `Sync` beside the profile it reads, so the sentences are testable without a window.
public enum FolderReading {

    /// Parent path → its immediate children, **including the root's own**.
    ///
    /// ``StructureDivergence/families(in:)`` builds the same relation and drops the root's children
    /// (their parent path is the empty string), which is right for a detector that needs a *family*
    /// of siblings and wrong for a tree view, whose top level is exactly that dropped set. Keyed
    /// under ``FolderSurveyBuilder/rootEntryPath`` so the root is addressed the same way the entry
    /// dictionary addresses it.
    public static func childrenByParent(_ profile: FolderProfile) -> [String: [String]] {
        var byParent: [String: [String]] = [:]
        for path in profile.folders.keys where path != FolderSurveyBuilder.rootEntryPath {
            let parent = (path as NSString).deletingLastPathComponent
            byParent[parent.isEmpty ? FolderSurveyBuilder.rootEntryPath : parent, default: []].append(path)
        }
        return byParent.mapValues { $0.sorted() }
    }

    /// The shape findings a reading can quote, keyed by the family they are about.
    ///
    /// Only ``FindingKind/shape`` — the others are about a single folder rather than what a folder
    /// holds, and none of them is a reading of the folder the tree row is showing.
    public static func shapeFindings(in profile: FolderProfile) -> [String: StructureFinding] {
        var byFamily: [String: StructureFinding] = [:]
        for finding in StructureDivergence.findings(in: profile) where finding.kind == .shape {
            byFamily[finding.family] = finding
        }
        return byFamily
    }

    /// One folder, in one line.
    ///
    /// The order of the rules is the order of the clauses below and is deliberate: the three
    /// lifecycle roles answer first because "this is an inbox" outranks anything about its shape,
    /// and a country folder is read as a country before it is read as whatever role it happens to
    /// carry, because that is what the user confirmed it was two screens ago.
    public static func reading(for path: String, in profile: FolderProfile,
                               children: [String: [String]],
                               shapes: [String: StructureFinding] = [:]) -> String {
        guard let entry = profile.folders[path] else { return "" }
        let name = (path as NSString).lastPathComponent

        // **Lifecycle before role, because the builder puts them on different fields.** An empty
        // `TODO` comes back with `role == .empty` and `lifecycle == "inbox"`; reading the role
        // first would call the app's own drop folder "empty" and say nothing about the one fact
        // that changes what filing does with it. Same for an `Archive` of 38 folders, which is a
        // container by role and left alone by lifecycle.
        switch entry.axes["lifecycle"] {
        case "inbox": return "inbox: nothing will be filed here"
        case "archive": return "archive: left as it is"
        default: break
        }

        switch entry.role {
        case .inbox: return "inbox: nothing will be filed here"
        case .archive: return "archive: left as it is"
        case .empty: return "empty"
        case .yearBucket: return join("a year", anchors: entry.anchors)
        default: break
        }

        // Its own name is the country, not one inherited from a parent — every folder below a `US`
        // carries the same axis value, and reading them all as countries would be wrong about all
        // but one of them.
        if entry.axes["jurisdiction"] == name { return "a country" }

        switch entry.role {
        case .personBucket: return "a person"
        case .destination: return join("files go here", anchors: entry.anchors)
        case .container, .passThrough:
            let kids = children[path] ?? []
            let people = kids.compactMap { profile.folders[$0]?.role == .personBucket
                ? (profile.folders[$0]?.axes["person"] ?? ($0 as NSString).lastPathComponent)
                : nil }
            if !kids.isEmpty, people.count == kids.count {
                return "a folder per person: " + people.joined(separator: ", ")
            }
            if let finding = shapes[path] {
                return "\(finding.memberCount) folders, \(finding.schemes.count) internal shapes"
            }
            if let sentence = shapeSentence(under: path, in: profile, children: children) {
                return sentence
            }
            return "holds folders only"
        default:
            return "holds folders only"
        }
    }

    /// `"a year · income, tax"` — the reading, then at most two anchors as the evidence for it.
    ///
    /// Two, because the anchors are there to make a row recognisable and a third has never yet
    /// been what told two rows apart; the profile keeps more and the tree row has one line.
    private static func join(_ reading: String, anchors: [String]) -> String {
        let shown = anchors.prefix(2)
        guard !shown.isEmpty else { return reading }
        return reading + " · " + shown.joined(separator: ", ")
    }

    /// `"a country first, then the year"` — what the levels below this folder are organised by.
    ///
    /// Read per depth rather than per branch: a tree where every country holds years is described
    /// by two words, and describing it branch by branch would put the same two words on screen once
    /// per country. Nil when there is nothing to describe — one level only, or a level too thin for
    /// a majority to mean anything.
    static func shapeSentence(under path: String, in profile: FolderProfile,
                              children: [String: [String]]) -> String? {
        var words: [String] = []
        var level = children[path] ?? []
        while level.count >= minimumFoldersPerLevel {
            var counts: [String: Int] = [:]
            for child in level { counts[axisWord(for: child, in: profile), default: 0] += 1 }
            // Ties break by the word, so the sentence does not depend on dictionary order.
            let word = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .first?.key ?? unknownAxisWord
            words.append(word)
            level = level.flatMap { children[$0] ?? [] }
        }
        guard words.count >= minimumLevels else { return nil }
        var sentence = words[0] + " first"
        for word in words.dropFirst() { sentence += ", then " + word }
        return sentence
    }

    /// A level thinner than this says nothing about a habit: one folder is an example, not a shape.
    static let minimumFoldersPerLevel = 2
    /// One level is a list; the sentence is about how levels *nest*, so two is the floor.
    static let minimumLevels = 2
    /// What a folder organised by nothing the profile records is called.
    static let unknownAxisWord = "the kind of thing"

    /// What this folder's own name contributes, as a word for the level it sits on.
    private static func axisWord(for path: String, in profile: FolderProfile) -> String {
        guard let entry = profile.folders[path] else { return unknownAxisWord }
        let name = (path as NSString).lastPathComponent
        if entry.axes["jurisdiction"] == name { return "a country" }
        if entry.axes["year"] == name || entry.axes["fiscalYear"] == name { return "the year" }
        if entry.axes["person"] == name || entry.role == .personBucket { return "a person" }
        return unknownAxisWord
    }
}
