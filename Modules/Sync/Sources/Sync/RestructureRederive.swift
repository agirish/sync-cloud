import Foundation

/// The pure halves of a re-derivation: the carry-over that keeps the old profile's judgements in
/// the re-derived one, and the key replay that moves the corpus with the tree. The apply engine
/// (`FileSyncManager+Restructure`) sequences these against the disk; nothing here touches it.
public extension FolderProfile {
    /// This profile with its provenance chain set: the one field
    /// ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)`` can't know,
    /// because only the apply knows what it replaced.
    func settingDerivedFrom(_ id: String) -> FolderProfile {
        FolderProfile(profileId: profileId, root: root, folders: folders,
                      personTokens: personTokens, personAliases: personAliases,
                      builtBy: builtBy, derivedFrom: id,
                      unknownRoles: unknownRoles, undecodableFolders: undecodableFolders)
    }
}

public enum RestructureRederive {

    // MARK: - What the manifest moved

    /// The directory-level mappings, in the order they ran: what folder keys re-prefix through.
    /// `rename-dir` and `move-dir` both move a directory; nothing else does.
    public static func renameMap(of manifest: RestructureManifest) -> [(from: String, to: String)] {
        manifest.actions.compactMap { action in
            guard action.action == .renameDir || action.action == .moveDir,
                  let src = action.src, let dst = action.dst else { return nil }
            return (from: src, to: dst)
        }
    }

    /// The file-level mappings: where each moved file is now, which is `collidedInto` when the
    /// landing had to pick a unique name (read the same way the inverse reads it).
    public static func fileMoves(of manifest: RestructureManifest) -> [(from: String, to: String)] {
        manifest.actions.compactMap { action in
            guard action.action == .moveFile, let src = action.src,
                  let dst = action.collidedInto ?? action.dst else { return nil }
            return (from: src, to: dst)
        }
    }

    /// The rename list with each step's child prefix built once. `mapped` runs for every folder in
    /// the profile and every document in the corpus, so building `rename.from + "/"` per call would
    /// make throwaway strings by the hundred thousand on the main actor.
    struct RenameSteps {
        /// `from`, its child prefix, and `to`. The prefix is what says a path sits beneath the
        /// renamed folder rather than sharing its name's letters (`A/BB` is not under `A/B`), the
        /// rule ``RestructureStore/rekey(renames:context:)`` documents.
        let steps: [(from: String, prefix: String, to: String)]

        init(_ renames: [(from: String, to: String)]) {
            steps = renames.map { (from: $0.from, prefix: $0.from + "/", to: $0.to) }
        }

        /// One path pushed through every step, in order. A fold, not a lookup, because a later
        /// rename may act on the product of an earlier one.
        func mapped(_ path: String) -> String {
            var current = path
            for step in steps {
                if current == step.from {
                    current = step.to
                } else if current.hasPrefix(step.prefix) {
                    current = step.to + "/" + current.dropFirst(step.prefix.count)
                }
            }
            return current
        }
    }

    /// One path pushed through the directory renames, in order, by component prefix (`A/BB` is not
    /// under `A/B`). For one path; a caller mapping many builds a ``RenameSteps`` once.
    public static func mapped(_ path: String, through renames: [(from: String, to: String)])
        -> String {
        RenameSteps(renames).mapped(path)
    }

    // MARK: - Step 6: the carry-over

    /// The freshly walked profile with the old one's judgements carried forward: for every path in
    /// both, directly or through this manifest's renames, `acceptsNewFiles`, `noIntakeReason` and
    /// `naming` come from the old entry. Only when the old entry holds one (non-nil): the
    /// carry-over keeps judgements a walk can't see, such as hand refusals, and must not erase what
    /// the walk did see with an old silence.
    public static func carryOver(from old: FolderProfile, into fresh: FolderProfile,
                                 through manifest: RestructureManifest) -> FolderProfile {
        let renames = RenameSteps(renameMap(of: manifest))
        var folders = fresh.folders
        // Two old paths can map onto one fresh path: a stale entry at a rename's destination whose
        // folder was hand-deleted, plus the renamed source itself. Decided, not left to dictionary
        // order: the entry that travelled through the manifest wins, then the lexically smaller.
        var carrier: [String: String] = [:]
        for oldPath in old.folders.keys {
            let newPath = renames.mapped(oldPath)
            guard let existing = carrier[newPath] else {
                carrier[newPath] = oldPath
                continue
            }
            let existingMoved = existing != newPath
            let candidateMoved = oldPath != newPath
            if candidateMoved != existingMoved {
                if candidateMoved { carrier[newPath] = oldPath }
            } else if oldPath < existing {
                carrier[newPath] = oldPath
            }
        }
        for (newPath, oldPath) in carrier {
            guard let oldEntry = old.folders[oldPath] else { continue }
            guard let walked = folders[newPath] else { continue }
            let carried = FolderProfileEntry(
                path: walked.path,
                role: walked.role,
                naming: oldEntry.naming ?? walked.naming,
                anchors: walked.anchors,
                acceptsNewFiles: oldEntry.acceptsNewFiles ?? walked.acceptsNewFiles,
                noIntakeReason: oldEntry.noIntakeReason ?? walked.noIntakeReason,
                fileCount: walked.fileCount,
                subfolderCount: walked.subfolderCount,
                axes: walked.axes)
            folders[newPath] = carried
        }
        return FolderProfile(profileId: fresh.profileId, root: fresh.root, folders: folders,
                             personTokens: fresh.personTokens,
                             personAliases: fresh.personAliases,
                             builtBy: fresh.builtBy, derivedFrom: fresh.derivedFrom,
                             unknownRoles: fresh.unknownRoles,
                             undecodableFolders: fresh.undecodableFolders)
    }

    /// The jurisdiction set a re-derivation walks with: the distinct entry-level values, never the
    /// header's list. The header can say `US, IN` while entries carry `Singapore`, and taking the
    /// header would lose that axis value.
    public static func entryJurisdictions(of profile: FolderProfile) -> Set<String> {
        Set(profile.folders.values.compactMap { $0.axes["jurisdiction"] })
    }

    // MARK: - Step 7: the key replay

    /// The corpus with every key moved the way the manifest moved its file: a `rename-dir`
    /// re-prefixes every key beneath it, a `move-file` re-keys one document, a merge re-keys each
    /// file it moved. The stamps don't move: a file that only moved wasn't re-read, which is the
    /// point of the replay.
    public static func rekeyedCorpus(_ corpus: FilingCorpus,
                                     through manifest: RestructureManifest) -> FilingCorpus {
        let renames = RenameSteps(renameMap(of: manifest))
        let moves = Dictionary(fileMoves(of: manifest),
                               uniquingKeysWith: { _, second in second })
        var rekeyed: [String: FilingCorpusDocument] = [:]
        rekeyed.reserveCapacity(corpus.documents.count)
        // Two passes, so a moved document colliding with a stale key at its destination (that file
        // was deleted since the last scan, so the apply saw no collision) resolves the same way
        // every run: the moved claim wins, as in `carryOver` and `RestructureStore.rekeyedMap`.
        var movedKeys: Set<String> = []
        for (path, document) in corpus.documents {
            // A file move names the document exactly; the directory renames re-prefix the rest. The
            // exact match runs first, or the dir map would re-prefix a merge source's files to a
            // path the merge never used.
            guard let newPath = moves[path] else { continue }
            rekeyed[newPath] = document
            movedKeys.insert(newPath)
        }
        for (path, document) in corpus.documents where moves[path] == nil {
            let newPath = renames.mapped(path)
            guard !movedKeys.contains(newPath) else { continue }
            rekeyed[newPath] = document
        }
        return FilingCorpus(profileId: corpus.profileId, salt: corpus.salt,
                            documents: rekeyed, surveyedAt: corpus.surveyedAt)
    }

    /// An unfinished survey's progress moved the way the manifest moved the tree, under the profile
    /// that now holds it. `read` goes through the corpus replay, the plan through the same two
    /// rules in the same order. The index is kept only when the plan kept its length: a collapse
    /// would slide it onto a document it never reached.
    public static func rekeyedCheckpoint(_ checkpoint: DocumentSurveyCheckpoint,
                                         through manifest: RestructureManifest,
                                         profileId: String) -> DocumentSurveyCheckpoint {
        let read = rekeyedCorpus(FilingCorpus(profileId: checkpoint.profileId,
                                              salt: checkpoint.salt,
                                              documents: checkpoint.read),
                                 through: manifest).documents
        let renames = RenameSteps(renameMap(of: manifest))
        let moves = Dictionary(fileMoves(of: manifest), uniquingKeysWith: { _, second in second })
        var seen: Set<String> = []
        let plan = checkpoint.plan.map { moves[$0] ?? renames.mapped($0) }
            .filter { seen.insert($0).inserted }
        return DocumentSurveyCheckpoint(
            profileId: profileId, rootPath: checkpoint.rootPath, salt: checkpoint.salt,
            plan: plan,
            nextIndex: plan.count == checkpoint.plan.count ? checkpoint.nextIndex : 0,
            read: read, documentsUnavailable: checkpoint.documentsUnavailable,
            startedAt: checkpoint.startedAt, updatedAt: checkpoint.updatedAt)
    }
}
