import Foundation

/// Derives a ``FolderProfile`` from a tree walk — the half of the filing artifacts the app has
/// never been able to produce for itself.
///
/// The profile that drives the Organize router, the rename planner and the classifier's
/// destination list has only ever come from an out-of-repo Python script, so a machine without one
/// has no way in: `resurveyFilingMemory` opens by requiring a `profileId` that only a profile
/// carries. `ROADMAP_V4.md` §4.2 is this type, and everything here is a **pure function of its
/// arguments** — no `FileManager`, no `Date()`, no defaults — so it can run inside a detached
/// background task and be tested against a fixture with nothing on disk.
///
/// ## What it does and does not claim
///
/// Every rule below was measured against the hand-built profile of the developer's own tree
/// (3,013 folders, `~/Documents`) by walking that tree and comparing field by field:
///
/// | field | agreement |
/// |---|---|
/// | `path`, `fileCount`, `subfolderCount` | 100% (tree drift aside) |
/// | `role` | 99.80% |
/// | `acceptsNewFiles` | 39 of 39 inboxes, no false positives |
/// | `anchors` (whole list, in order) | 99.73% |
/// | `axes.lifecycle` | 99.87% |
/// | `axes.year`, `axes.fiscalYear` | 100% |
/// | `axes.person` | 99.80% |
/// | `axes.jurisdiction` | 100%, given the declared values |
///
/// **`naming` is left nil, deliberately, and that is not a gap to be filled later.** Two reasons.
/// `ROADMAP_V4.md` §4.2: a wrong `naming` would have the rename pass propose renames toward a
/// convention nobody actually has — silently, because a rename plan looks the same whether its
/// premise is right or wrong. And ``FolderProfileEntry/naming`` is decoded but read nowhere outside
/// test fixtures, so accuracy there buys nothing today. Guessing costs; abstaining does not.
///
/// **A profile built here must never be written over a hand-built one.** These rules re-derive what
/// a walk can see; the hand-built profile also records judgements about names that a walk cannot
/// (`folderSemantics`, `naming`, the `outbound-pack` refusals). The store's first-write guard is
/// where that is enforced — this type only produces the value.
public enum FolderSurveyBuilder {

    /// Builds a profile from the nodes **directly inside** `root`.
    ///
    /// - Parameters:
    ///   - tree: the root's own children, as a walk produced them. Nested `children` are read
    ///     recursively; a directory marked ``FileNode/isUnexplored`` contributes to its parent's
    ///     `subfolderCount` but gets no entry of its own, because its counts would be fiction.
    ///     Symlinks are skipped entirely (a link and its in-tree target would otherwise be surveyed
    ///     twice, and a link out of the tree is not this tree's folder).
    ///   - root: what the profile records as the tree it describes, e.g. `~/Documents`. Never
    ///     touched on disk and never parsed — entry paths are built from node *names*, so a walk
    ///     whose ids are absolute, relative or synthetic all produce the same profile.
    ///   - registry: the household, for the person axis and the `person-bucket` role. Pass nil and
    ///     both are simply absent — no folder is misattributed for want of a roster.
    ///   - jurisdictionValues: the declared jurisdiction vocabulary (`US`, `IN`, …). The tree cannot
    ///     be asked which of its folder names are jurisdictions — `Singapore` is one and `Chase` is
    ///     not, and nothing in either name says so — so this is handed in, matched as a whole
    ///     component, case-sensitively. Empty means the axis is never recorded.
    public static func build(tree: [FileNode], root: String, profileId: String,
                             registry: PersonRegistry?,
                             jurisdictionValues: Set<String> = []) -> FolderProfile {
        var entries: [String: FolderProfileEntry] = [:]
        let roster = rosterForms(registry)
        // **Tolerant of a duplicated id, because `people.json` is hand-edited and nothing upstream
        // rejects one.** `Dictionary(uniqueKeysWithValues:)` traps on a repeated key, so a
        // copy-pasted person block whose id was not changed killed the process here.
        // ``PersonRegistry/init(people:source:)`` itself just overwrites, so the file loads fine and
        // the crash lands somewhere else entirely — this was not the only such site, and the People
        // settings pane had the same trap on the main actor.
        //
        // Last one wins, matching the registry's `tokensByPerson`, which is what decides who
        // ``PersonRegistry/detect(in:)`` resolves that id to — so the axis value and the matcher
        // agree. The registry is not uniformly last-wins: `displayForm` and `tokenBreakdown` reach
        // for `people.first(where:)`, so with a duplicated id they answer from the *first* record.
        // Nothing here can fix that; keying off the same map `detect` uses is this type's half.
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
            // The one inbox rule in the codebase, asked of the whole path: a folder *under* `TODO`
            // is as unfileable as `TODO` itself. Only an explicit `false` forbids filing, so
            // everything else stays nil rather than claiming a permission the walk never checked.
            acceptsNewFiles: FolderProfile.isInboxPath(relativePath) ? false : nil,
            fileCount: fileNames.count,
            subfolderCount: subfolderCount,
            axes: axes(relativePath: relativePath, components: components,
                       registry: registry, displayNames: displayNames,
                       jurisdictionValues: jurisdictionValues))
    }

    // MARK: - Role

    /// What a folder **is**, from its own name and its counts. Measured 99.80% against the
    /// hand-built profile.
    ///
    /// The order of these tests is load-bearing and each one was measured:
    ///
    /// - **Empty first.** `Finance/US/Income Tax/2025/Income/TODO` holds nothing and the profile
    ///   calls it `empty`, not `inbox` — an empty inbox is still empty, and `acceptsNewFiles`
    ///   already carries the refusal.
    /// - **Inbox on the folder's OWN name, not the path.** ``FolderProfile/isInboxPath`` is the one
    ///   inbox rule and it is reused here — but asked of the leaf. Asking it of the whole path
    ///   drops role agreement from 99.80% to **99.20%**: `Finance/US/TODO/IRS/2023` is a
    ///   `year-bucket` in the profile, not an inbox. Its *permission* is another matter, which is
    ///   why `acceptsNewFiles` above does ask the whole path.
    /// - **Archive on the folder's own name too.** Any-component matching costs the same way:
    ///   `…/Archive/Standard Chartered/2010` is a `year-bucket`, and the `archive` fact about it is
    ///   carried by `axes.lifecycle`, which *does* propagate. Any-component matching measured
    ///   99.20% against 99.80%.
    /// - **Year before person**, so a folder called `2019` never has to be checked against a roster.
    /// - **Person only on an exact roster name.** `Credit 1892 (Shweta)` and `Chase/Shweta 2024`
    ///   *detect* a person and are `destination`s in the profile; asking the matcher instead of
    ///   requiring the whole name measured 99.17%.
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

    /// Every name form the household answers to, lowercased — display names, full names, aliases.
    ///
    /// Taken off ``PersonRegistry/people`` rather than re-derived: the roster is the registry's
    /// data, and a second list of "who counts as a person folder" would drift the first time
    /// somebody adds an alias.
    static func rosterForms(_ registry: PersonRegistry?) -> Set<String> {
        var out = Set<String>()
        for person in registry?.people ?? [] {
            // ``Person/nameForms`` rather than the union spelled out again: the registry answers
            // four other questions with the same union, and a fifth copy here is what would let
            // `person-bucket` role detection stop matching a form that ``PersonRegistry/detect(in:)``
            // — called one function away, for the person axis — still matches.
            for form in person.nameForms { out.insert(form.lowercased()) }
        }
        return out
    }

    static let archiveComponent = "Archive"

    // MARK: - Axes

    /// The axis values in play for a folder, read off the whole path so they propagate downward —
    /// `Finance/US/Income Tax/2025/Income` is a US folder and a 2025 folder because its ancestors
    /// say so. **Deeper wins** on every axis: a `2024` folder inside a `2023` one is about 2024.
    static func axes(relativePath: String, components: [String],
                     registry: PersonRegistry?, displayNames: [String: String],
                     jurisdictionValues: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for component in components {
            // A bare year is one part (`2023`), a fiscal year two (`2013-2014`). Split without
            // trimming, deliberately: `2006 - 2007` — spaces around the dash — is a folder *name*
            // in this tree and the profile records no year axis for it. Both directions measured
            // 100%. ``FolderProfileEntry/looksLikeYear`` is the shared shape test; the part count
            // is what says which axis it lands on.
            if FolderProfileEntry.looksLikeYear(component) {
                let parts = component.split(separator: "-", omittingEmptySubsequences: false)
                // **Both keys are kept when a path carries both**, deliberately, and the hand-built
                // profile does the same — four folders on the reference tree record a `year` and a
                // `fiscalYear` together (`…/H-1B/2016-2019/…/2016`), because both are true of them:
                // the folder is about 2016, inside the 2016-2019 petition. Clearing one to make
                // "deeper wins" hold between the keys was tried and is wrong — it throws away a fact
                // the offline builder records, and it drops the ground truth's year agreement off
                // 100%. Which of the two a *consumer* should answer with is a question about depth,
                // and depth is in the path, so ``FolderProfileEntry/yearKey`` settles it there.
                out[parts.count == 1 ? "year" : "fiscalYear"] = component
            }
            if jurisdictionValues.contains(component) { out["jurisdiction"] = component }
            if let registry {
                let ids = registry.detect(in: component)
                // **Exactly one, or nobody.** A component naming two people ("Abhishek & Shweta")
                // is not evidence for either, and picking one arbitrarily would file a joint
                // document under half its owners. Leaving the ancestor's value standing is right:
                // the shallower folder still describes this one.
                if ids.count == 1, let id = ids.first, let name = displayNames[id] {
                    out["person"] = name
                }
            }
        }
        // Lifecycle is the one axis read off the whole path rather than per component, because it
        // *is* the propagating fact: everything under `Archive/` is archived, everything under
        // `TODO/` is unfiled. Measured 99.87% — the four misses are folders like `TODO - 2023`,
        // which name an inbox in passing without being one.
        out["lifecycle"] = FolderProfile.isInboxPath(relativePath) ? "inbox"
            : (components.contains(archiveComponent) ? "archive" : "active")
        return out
    }

    // MARK: - Anchors

    /// Tokens mined from the folder's last two path components and its first 40 filenames, ranked
    /// by count and capped at ten. Measured **99.73% exact-list** agreement.
    ///
    /// The keep rule is *count ≥ 2, or the token names one of those two path components*: a word
    /// two files share is a subject, a word one file mentions is noise, and the folder's own name
    /// is a subject however many files repeat it. Ranking is count-descending, ties broken by first
    /// appearance (path components before files, parent before child), which is what makes the list
    /// an order and not a set.
    ///
    /// Every parameter here was swept against the real profile, and the neighbouring values are
    /// worse by a lot — this is not a set of round numbers somebody liked:
    ///
    /// | knob | chosen | next best |
    /// |---|---|---|
    /// | path components | last 2 → 99.73% | last 1 → 21.35%, last 3 → 17.93% |
    /// | filename cap | 40 → 99.73% | 20 → 98.97%, unbounded → 99.70% |
    /// | token cap | 10 → 99.73% | 9 → 97.51%, 12 → 97.94% |
    ///
    /// The tokenizer is a parameter for one reason: the ground-truth suite re-measures this whole
    /// pipeline with ``FilingRouter/tokenize`` swapped in, so the 30-point gap that justifies two
    /// tokenizers is *derived* on the real tree rather than quoted from a comment. Production has
    /// exactly one caller and it takes the default.
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
            // A month is a filing *date*, not a subject — except when the folder is named for one
            // (`Lacewings JAN`), where it is the only thing distinguishing that folder from its
            // siblings. Dropping months unconditionally measured 99.20%.
            return !(monthWords.contains(token) && !fromPath.contains(token))
        }
        // Decorated sort because `sorted(by:)` is not stable: the first-seen index is what keeps
        // ties in path-then-file order, and without it the list would reshuffle between runs of the
        // same walk.
        return kept.sorted {
            let (a, b) = (counts[$0.element] ?? 0, counts[$1.element] ?? 0)
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(anchorLimit).map(\.element)
    }

    static let pathComponentDepth = 2
    static let fileNameSample = 40
    static let anchorLimit = 10

    /// Words that describe a document's *packaging* rather than its subject. Every one was
    /// confirmed against the hand-built profile: each appears in folder names or filenames in this
    /// tree and is never recorded as an anchor (`form` in 133 folder names, `forms` in 99,
    /// `documents` in 43 — all dropped).
    ///
    /// Note `statements` is deliberately absent while `statement` is present: 145 folders are
    /// *named* `Statements` and the profile keeps the token every time. The list is what was
    /// measured, not what looks symmetrical.
    static let anchorStopWords: Set<String> = [
        "form", "forms", "document", "documents", "statement", "file", "files", "page", "pages",
        "copy", "all", "and", "the", "for", "with", "from", "not", "yes", "total", "more",
    ]

    /// Month names as this tree writes them.
    ///
    /// **Derived from ``OrdinalMonthName``'s tables rather than retyped**, because the module would
    /// otherwise hold two month vocabularies with nothing keeping them level: a spelling added there
    /// — that table drives filed-name canonicalisation — would never reach anchor suppression, and
    /// the rename pass would treat a token as a date while the profile recorded it as a subject.
    /// The union of the abbreviations and the full names is exactly the list this used to spell out;
    /// `theMonthVocabularyTracksTheRenamer` pins that.
    ///
    /// `sept` is deliberately **not** in either table — the profile keeps it as an anchor (6
    /// folders), and a list assembled by symmetry rather than by measurement would have thrown it
    /// away. Deriving preserves that: `sept` is absent because nothing measured put it there.
    /// Both tables are lowercased here rather than trusted to be lowercase. `monthFullNames` happens
    /// to be stored that way and its own doc only promises it is for *recognising* a month, while the
    /// tokens matched against this set (``anchorWords(_:)``) are always lowercased — so a
    /// capitalisation there would silently stop month suppression for all twelve full names.
    static let monthWords: Set<String> = Set(
        (OrdinalMonthName.monthAbbreviations + OrdinalMonthName.monthFullNames).map { $0.lowercased() })

    /// The anchor tokenizer: lowercased runs matching `[a-z][a-z0-9&+-]{2,}` — a letter, then at
    /// least two more letters, digits, `&`, `+` or `-`.
    ///
    /// **This is NOT ``FilingRouter/tokenize`` and must not be "unified" with it.** Measured on the
    /// real tree, twice. Substituting `FilingRouter.tokenize` for the token *set* alone dropped
    /// exact-list agreement from **99.83% to 68.66%** (852 tokens gained, 228 lost); re-running the
    /// whole pipeline through it — which is what a unification would actually do — measures
    /// **32.01% against 99.73%**, and `theRoutersTokenizerWouldBeMuchWorseHere` re-derives that
    /// number on every run rather than trusting this comment. The two rules disagree on three
    /// things that matter here. `tokenize` splits on every non-alphanumeric, so `PG&E`,
    /// `parents-in-law` and `re-KYC` shatter into fragments the profile records whole; it accepts
    /// two-character tokens, which floods a folder's list with `jn`, `iob` and `nb`; and it applies
    /// a 60-word stop list built for *document text* (`california`, `united`, `states`, `new`,
    /// `pdf`, `email`) that deletes tokens this tree's folder names genuinely turn on.
    ///
    /// The two exist for different jobs. `tokenize` feeds a scorer that must agree byte for byte
    /// with the memory builder that wrote its index — its own doc says changing it fails silently.
    /// This one feeds a human-readable list of what a folder is *about*. Keeping them apart is what
    /// lets each be right.
    static func anchorWords(_ text: String) -> [String] {
        var out: [String] = []
        var run = ""
        func flush() {
            defer { run = "" }
            // The regex matches from the first letter in the run, so `2026-report` yields `report`
            // and `1b-visa` yields `b-visa` — the leading digits are not part of any match.
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
    /// into. Dot-files are excluded from both — `.DS_Store` is not a document and would put every
    /// folder's `fileCount` one over what the survey recorded — and so are symlinks.
    ///
    /// **Filenames are sorted here, not left in walk order**, because only the first
    /// ``fileNameSample`` of them reach the anchors: `FileManager` promises no enumeration order,
    /// so an unsorted walk would give the same folder different anchors on different runs — and the
    /// profile is a persisted, fingerprinted artifact. Sorting costs nothing and makes the whole
    /// builder a function of the tree rather than of the order it happened to be read in.
    static func partition(_ children: [FileNode]) -> (files: [String], folders: [FileNode]) {
        var files: [String] = []
        var folders: [FileNode] = []
        for node in children where isSurveyed(node) {
            if node.isDirectory { folders.append(node) } else { files.append(node.name) }
        }
        return (files.sorted(), folders)
    }

    /// Whether the survey counts `node` at all.
    ///
    /// Dot-files are not documents — `.DS_Store` would put every folder's `fileCount` one over what
    /// the survey recorded — and a symlink is skipped because a link and its in-tree target would
    /// be surveyed twice, while a link out of the tree is not this tree's folder.
    ///
    /// Internal: the folder half of this rule is what other types need, and that is
    /// ``isSurveyedFolder(_:)`` below.
    static func isSurveyed(_ node: FileNode) -> Bool {
        !node.name.hasPrefix(".") && node.isSymbolicLink != true
    }

    /// Whether the survey gives `node` an entry of its own and descends into it.
    ///
    /// An unexplored directory fails this while still passing ``isSurveyed(_:)``: it counts toward
    /// its parent's `subfolderCount`, because it is really there, but it gets no entry, because its
    /// own counts would be fiction — `children == []` on such a node is a construction artifact,
    /// not an observation.
    ///
    /// **Public because it is the definition of "a folder this survey covers", and a second opinion
    /// about that is a defect rather than a duplication.** ``JurisdictionCandidates`` proposes axis
    /// values by counting folders and reports how many would take each one; when it filtered only on
    /// `isDirectory` it counted dot-directories, symlinks and unexplored subtrees that the survey
    /// then never gave an entry to, so the blast radius shown to the user was for a tree the survey
    /// does not walk.
    public static func isSurveyedFolder(_ node: FileNode) -> Bool {
        node.isDirectory && isSurveyed(node) && node.isUnexplored != true
    }
}
