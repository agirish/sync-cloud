import Foundation

/// What a folder's profile entry says, in the user's words ("holds folders only", "a year") rather
/// than the profile's (`pass-through`, `year-bucket`), for the Structure screen. Decides nothing:
/// each reading restates an entry ``FolderSurveyBuilder`` produced, so a wrong one is a wrong
/// sentence, never a wrong profile. In `Sync`, so the sentences test without a window.
public enum FolderReading {

    /// Parent path → its immediate children, including the root's, which
    /// ``StructureDivergence/families(in:)`` drops but a tree view needs as its top level. Keyed
    /// under ``FolderSurveyBuilder/rootEntryPath``, as the entry dictionary addresses the root.
    public static func childrenByParent(_ profile: FolderProfile) -> [String: [String]] {
        var byParent: [String: [String]] = [:]
        for path in profile.folders.keys where path != FolderSurveyBuilder.rootEntryPath {
            let parent = (path as NSString).deletingLastPathComponent
            byParent[parent.isEmpty ? FolderSurveyBuilder.rootEntryPath : parent, default: []].append(path)
        }
        return byParent.mapValues { $0.sorted() }
    }

    /// The shape findings a reading can quote, keyed by family. Only ``FindingKind/shape``: the
    /// other kinds are about a single folder, not what it holds.
    public static func shapeFindings(in profile: FolderProfile) -> [String: StructureFinding] {
        var byFamily: [String: StructureFinding] = [:]
        for finding in StructureDivergence.findings(in: profile) where finding.kind == .shape {
            byFamily[finding.family] = finding
        }
        return byFamily
    }

    /// One folder, in one line. The clause order is deliberate: inbox and archive answer first,
    /// because they outrank anything about shape, and a country folder reads as a country before
    /// its role, since that is what the user confirmed it was.
    public static func reading(for path: String, in profile: FolderProfile,
                               children: [String: [String]],
                               shapes: [String: StructureFinding] = [:]) -> String {
        guard let entry = profile.folders[path] else { return "" }
        let name = (path as NSString).lastPathComponent

        // Lifecycle before role, since the builder records them separately: an empty `TODO` has
        // `role == .empty` and `lifecycle == "inbox"`, and "empty" would hide what filing does
        // with it. Likewise an `Archive` whose role is container.
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

        // Only when its own name is the country: every folder below a `US` inherits the axis value.
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

    /// `"a year · income, tax"`: the reading, then at most two anchors as evidence, enough to make a
    /// one-line row recognisable.
    private static func join(_ reading: String, anchors: [String]) -> String {
        let shown = anchors.prefix(2)
        guard !shown.isEmpty else { return reading }
        return reading + " · " + shown.joined(separator: ", ")
    }

    /// `"a country first, then the year"`: what the levels below this folder are organised by. Read
    /// per depth, not per branch, so a tree where every country holds years is two words, not two
    /// per country. Nil for one level only, or a level too thin for a majority to mean anything.
    static func shapeSentence(under path: String, in profile: FolderProfile,
                              children: [String: [String]]) -> String? {
        var words: [String] = []
        var level = children[path] ?? []
        while level.count >= minimumFoldersPerLevel {
            var counts: [String: Int] = [:]
            for child in level { counts[axisWord(for: child, in: profile), default: 0] += 1 }
            // Ties break by the word, so the sentence doesn't depend on dictionary order.
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
