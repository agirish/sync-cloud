import Foundation

/// Derives a ``FolderProfile`` from a tree walk, so a machine without the out-of-repo builder can
/// still get the profile that drives the Organize router, the rename planner and the classifier's
/// destination list (`resurveyFilingMemory` needs its `profileId`). A pure function of its
/// arguments, with no `FileManager`, `Date()` or defaults, so it runs in a detached task and tests
/// against a fixture.
///
/// Each rule was checked field by field against a hand-built profile of a real ~3,000-folder tree:
/// paths, counts and year axes agree fully, and role, anchors, lifecycle and person at 99.7% or
/// better.
///
/// **`naming` is left nil, deliberately.** ``RenamePlanner`` reads it, and a wrong convention would
/// have the rename pass propose renames toward a scheme nobody uses, with nothing looking wrong;
/// with nil it infers from the folder's own files instead.
///
/// **A profile built here must never be written over a hand-built one**, which records judgements
/// a walk can't (`folderSemantics`, `naming`, `outbound-pack` refusals). The store's guard enforces
/// that; this type only produces the value.
public enum FolderSurveyBuilder {

    /// The key the root's own entry is filed under. Every profile has it, so a folder count of one
    /// means nothing was found below the root; a `folders.isEmpty` guard can never fire.
    public static let rootEntryPath = "."


    /// Builds a profile from the nodes **directly inside** `root`.
    ///
    /// - Parameters:
    ///   - tree: the root's own children, as a walk produced them. Nested `children` are read
    ///     recursively; a directory marked ``FileNode/isUnexplored`` counts toward its parent's
    ///     `subfolderCount` but gets no entry, since its counts would be fiction. Symlinks are
    ///     skipped (no double survey of an in-tree target, no folder from outside the tree).
    ///   - root: what the profile records as its tree, e.g. `~/Documents`. Never touched or parsed:
    ///     entry paths come from node names, so absolute, relative or synthetic ids all agree.
    ///   - registry: the household, for the person axis and the `person-bucket` role. With nil, both
    ///     are absent rather than guessed.
    ///   - jurisdictionValues: the declared jurisdiction vocabulary (`US`, `IN`, …), since nothing in
    ///     a name says `Singapore` is one and `Chase` isn't. Matched as a whole component,
    ///     case-sensitively. Empty means the axis is never recorded.
    public static func build(tree: [FileNode], root: String, profileId: String,
                             registry: PersonRegistry?,
                             jurisdictionValues: Set<String> = []) -> FolderProfile {
        var entries: [String: FolderProfileEntry] = [:]
        let roster = rosterForms(registry)
        // Tolerates a duplicated person id rather than trapping as `uniqueKeysWithValues:` would.
        // ``PersonRegistry/init(people:source:)`` already collapses repeats, so this is a second
        // defence (like the one in `SettingsView.allFacts`) in case that regresses. Last one wins,
        // the collapse's own rule, so this agrees with the roster.
        let displayNames = Dictionary((registry?.people ?? []).map { ($0.id, $0.displayName) },
                                      uniquingKeysWith: { _, latest in latest })

        func visit(_ children: [FileNode], at relativePath: String, components: [String]) {
            let (files, folders) = partition(children)
            entries[relativePath] = entry(
                relativePath: relativePath, components: components,
                fileNames: files, subfolderCount: folders.count,
                roster: roster, registry: registry, displayNames: displayNames,
                jurisdictionValues: jurisdictionValues)
            for folder in folders where isSurveyedFolder(folder) {
                let child = components + [folder.name]
                visit(folder.children ?? [], at: child.joined(separator: "/"), components: child)
            }
        }
        visit(tree, at: rootPath, components: [])

        var tokens = Set<String>()
        var aliases: [String: String] = [:]
        for person in registry?.people ?? [] {
            tokens.insert(person.displayName.lowercased())
            for alias in person.aliases {
                tokens.insert(alias.lowercased())
                aliases[alias.lowercased()] = person.displayName.lowercased()
            }
        }
        return FolderProfile(profileId: profileId, root: root, folders: entries,
                             personTokens: tokens, personAliases: aliases)
    }

    /// How the on-disk profile spells the root of the tree it describes.
    public static let rootPath = "."

    // MARK: - One folder

    static func entry(relativePath: String, components: [String],
                      fileNames: [String], subfolderCount: Int,
                      roster: Set<String>, registry: PersonRegistry?,
                      displayNames: [String: String],
                      jurisdictionValues: Set<String>) -> FolderProfileEntry {
        let ownName = components.last ?? rootPath
        return FolderProfileEntry(
            path: relativePath,
            role: role(ownName: ownName, fileCount: fileNames.count,
                       subfolderCount: subfolderCount, roster: roster),
            naming: nil,
            anchors: anchors(components: components, fileNames: fileNames),
            // The inbox rule, asked of the whole path: a folder under `TODO` is as unfileable as
            // `TODO`. Otherwise nil, not `true`, since the walk never checked a permission.
            acceptsNewFiles: FolderProfile.isInboxPath(relativePath) ? false : nil,
            fileCount: fileNames.count,
            subfolderCount: subfolderCount,
            axes: axes(relativePath: relativePath, components: components,
                       registry: registry, displayNames: displayNames,
                       jurisdictionValues: jurisdictionValues))
    }

    // MARK: - Role

    /// What a folder is, from its own name and counts. The order of the tests matters:
    ///
    /// - **Empty first.** An empty inbox is still empty; `acceptsNewFiles` carries the refusal.
    /// - **Inbox on the folder's own name**, not the path: `TODO/IRS/2023` is a year bucket. Its
    ///   permission is another matter, so `acceptsNewFiles` does ask the whole path.
    /// - **Archive on its own name too**: the archived fact about what is below is carried by
    ///   `axes.lifecycle`, which propagates.
    /// - **Year before person**, so `2019` never needs a roster check.
    /// - **Person only on an exact roster name.** `Credit 1892 (Mother)` mentions a person but is a
    ///   destination.
    static func role(ownName: String, fileCount: Int, subfolderCount: Int,
                     roster: Set<String>) -> FolderRole {
        if fileCount == 0 && subfolderCount == 0 { return .empty }
        if FolderProfile.isInboxPath(ownName) { return .inbox }
        if ownName == archiveComponent { return .archive }
        if FolderProfileEntry.looksLikeYear(ownName) { return .yearBucket }
        if roster.contains(ownName.lowercased()) { return .personBucket }
        if fileCount == 0 { return subfolderCount == 1 ? .passThrough : .container }
        return .destination
    }

    /// Every name form the household answers to, lowercased: display names, full names, aliases.
    /// Taken from ``PersonRegistry/people``, so a second list can't drift when an alias is added.
    static func rosterForms(_ registry: PersonRegistry?) -> Set<String> {
        var out = Set<String>()
        // Every record the registry holds, one per id (``PersonRegistry/init(people:source:)``
        // collapses repeats), so this sees the roster the rest of the app sees.
        for person in registry?.people ?? [] {
            // ``Person/nameForms``, the union the registry uses elsewhere, so role detection
            // matches the same forms as ``PersonRegistry/detect(in:)`` does for the person axis.
            for form in person.nameForms { out.insert(form.lowercased()) }
        }
        return out
    }

    static let archiveComponent = "Archive"

    // MARK: - Axes

    /// The axis values in play for a folder, read off the whole path so they propagate downward:
    /// `Finance/US/Income Tax/2025/Income` is US and 2025 because its ancestors say so. Deeper wins
    /// on each axis: a `2024` folder inside a `2023` one is about 2024.
    static func axes(relativePath: String, components: [String],
                     registry: PersonRegistry?, displayNames: [String: String],
                     jurisdictionValues: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for component in components {
            // A bare year is one part (`2023`), a fiscal year two (`2013-2014`). Not trimmed:
            // `2006 - 2007`, with spaces, is a folder name, not a year axis.
            // ``FolderProfileEntry/looksLikeYear`` tests the shape; the part count picks the axis.
            if FolderProfileEntry.looksLikeYear(component) {
                let parts = component.split(separator: "-", omittingEmptySubsequences: false)
                // Both keys are kept when a path carries both, as the hand-built profile does:
                // `…/2016-2019/…/2016` is about 2016, inside the 2016-2019 span. Which one a
                // consumer answers with is a depth question, settled by
                // ``FolderProfileEntry/yearKey``.
                out[parts.count == 1 ? "year" : "fiscalYear"] = component
            }
            if jurisdictionValues.contains(component) { out["jurisdiction"] = component }
            if let registry {
                let ids = registry.detect(in: component)
                // Exactly one, or nobody: "Father & Mother" is evidence for neither, and picking
                // one would file a joint document under half its owners. The ancestor's value
                // stands.
                if ids.count == 1, let id = ids.first, let name = displayNames[id] {
                    out["person"] = name
                }
            }
        }
        // Lifecycle is read off the whole path, not per component: everything under `Archive/` is
        // archived, everything under `TODO/` unfiled. (A name like `TODO - 2023` reads as an inbox
        // here even when it isn't one.)
        out["lifecycle"] = FolderProfile.isInboxPath(relativePath) ? "inbox"
            : (components.contains(archiveComponent) ? "archive" : "active")
        return out
    }

    // MARK: - Anchors

    /// Tokens mined from the folder's last two path components and its first 40 filenames, ranked
    /// by count and capped at ten. Kept: count ≥ 2, or a token of those path components (a word two
    /// files share is a subject; one file's word is noise). Ties break by first appearance, path
    /// before files, parent before child.
    ///
    /// The three numbers were swept against the hand-built profile; their neighbours agree worse
    /// (one or three path components are far worse). The tokenizer is a parameter only so the
    /// ground-truth suite can measure ``FilingRouter/tokenize`` in its place.
    static func anchors(components: [String], fileNames: [String],
                        tokenizer: (String) -> [String] = anchorWords) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        func add(_ token: String) {
            if counts[token] == nil { order.append(token) }
            counts[token, default: 0] += 1
        }
        for component in components.suffix(pathComponentDepth) {
            for token in tokenizer(component) { add(token) }
        }
        let fromPath = Set(order)
        for name in fileNames.prefix(fileNameSample) {
            for token in tokenizer((name as NSString).deletingPathExtension) { add(token) }
        }
        let kept = order.enumerated().filter { _, token in
            guard (counts[token] ?? 0) >= 2 || fromPath.contains(token) else { return false }
            guard !anchorStopWords.contains(token) else { return false }
            // A month is a filing date, not a subject, unless the folder is named for one
            // (`Lacewings JAN`), where it tells the folder from its siblings.
            return !(monthWords.contains(token) && !fromPath.contains(token))
        }
        // Decorated sort because `sorted(by:)` isn't stable: the first-seen index keeps ties in
        // order, or the list would reshuffle between runs of the same walk.
        return kept.sorted {
            let (a, b) = (counts[$0.element] ?? 0, counts[$1.element] ?? 0)
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(anchorLimit).map(\.element)
    }

    static let pathComponentDepth = 2
    static let fileNameSample = 40
    static let anchorLimit = 10

    /// Words for a document's packaging rather than its subject, each confirmed against the
    /// hand-built profile, which never keeps them as anchors. `statements` is deliberately absent
    /// though `statement` is present: folders named `Statements` keep it. Measured, not symmetrical.
    static let anchorStopWords: Set<String> = [
        "form", "forms", "document", "documents", "statement", "file", "files", "page", "pages",
        "copy", "all", "and", "the", "for", "with", "from", "not", "yes", "total", "more",
    ]

    /// Month names as this tree writes them, derived from ``OrdinalMonthName``'s tables so the
    /// renamer and anchor suppression share one vocabulary (`theMonthVocabularyTracksTheRenamer`).
    /// `sept` is in neither table, deliberately: the hand-built profile keeps it as an anchor.
    /// Lowercased here because ``anchorWords(_:)`` tokens are, and a capitalised table entry would
    /// silently stop suppression.
    static let monthWords: Set<String> = Set(
        (OrdinalMonthName.monthAbbreviations + OrdinalMonthName.monthFullNames).map { $0.lowercased() })

    /// The anchor tokenizer: lowercased runs matching `[a-z][a-z0-9&+-]{2,}`, a letter then at least
    /// two more letters, digits, `&`, `+` or `-`.
    ///
    /// **Not ``FilingRouter/tokenize``, and must not be unified with it**: through that tokenizer
    /// anchor agreement falls from near-total to about a third
    /// (`theRoutersTokenizerWouldBeMuchWorseHere` measures it). It shatters `PG&E` and
    /// `parents-in-law`, keeps two-letter noise, and stops words folder names turn on. That one must
    /// match the memory builder byte for byte; this one lists what a folder is about.
    static func anchorWords(_ text: String) -> [String] {
        var out: [String] = []
        var run = ""
        func flush() {
            defer { run = "" }
            // A match starts at the run's first letter: `2026-report` yields `report`, `1b-visa`
            // yields `b-visa`.
            guard let start = run.firstIndex(where: { $0.isASCII && $0.isLetter }) else { return }
            let token = String(run[start...])
            if token.count >= 3 { out.append(token) }
        }
        for character in text.lowercased() {
            let isWord = (character.isASCII && (character.isLetter || character.isNumber))
                || character == "&" || character == "+" || character == "-"
            if isWord { run.append(character) } else { flush() }
        }
        flush()
        return out
    }

    // MARK: - Walking

    /// Splits one directory's children into the filenames that count and the subfolders to descend
    /// into, leaving out dot-files and symlinks (``isSurveyed(_:)``).
    ///
    /// **A package is a file here**: a `.pages`, `.band` or Photos library is one document, as
    /// Restructure's disk view lists it. Descending would let a plan move a document's insides.
    ///
    /// **Filenames are sorted**, because only the first ``fileNameSample`` reach the anchors and
    /// `FileManager` promises no order: unsorted, one folder could get different anchors per run in
    /// a persisted, fingerprinted artifact.
    static func partition(_ children: [FileNode]) -> (files: [String], folders: [FileNode]) {
        var files: [String] = []
        var folders: [FileNode] = []
        for node in children where isSurveyed(node) {
            if node.isDirectory && !node.isPackage { folders.append(node) } else { files.append(node.name) }
        }
        return (files.sorted(), folders)
    }

    /// Whether the survey counts `node` at all. Dot-files aren't documents (`.DS_Store` would
    /// inflate every `fileCount`), and a symlink would survey its in-tree target twice or bring in a
    /// folder from outside the tree. Other types use ``isSurveyedFolder(_:)``.
    static func isSurveyed(_ node: FileNode) -> Bool {
        !node.name.hasPrefix(".") && node.isSymbolicLink != true
    }

    /// Whether the survey gives `node` an entry of its own and descends into it. An unexplored
    /// directory passes ``isSurveyed(_:)`` and counts toward its parent's `subfolderCount`, but gets
    /// no entry: its empty `children` is an artifact, not an observation.
    ///
    /// Public because it defines "a folder this survey covers", and any second opinion is a defect:
    /// ``JurisdictionCandidates`` counts with it, so the folder counts it shows the user match what
    /// the survey walks.
    public static func isSurveyedFolder(_ node: FileNode) -> Bool {
        node.isDirectory && !node.isPackage && isSurveyed(node) && node.isUnexplored != true
    }
}
