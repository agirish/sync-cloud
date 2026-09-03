import Foundation

/// §5.5 steps 6 and 7 as pure functions: the carry-over that makes a re-derived profile keep the
/// old one's judgements, and the key replay that moves the corpus with the tree. The apply engine
/// (`FileSyncManager+Restructure`) sequences these against the disk; nothing here touches it.
public extension FolderProfile {
    /// This profile with its provenance chain set — the one field
    /// ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)`` cannot
    /// know, because only the apply knows what it replaced.
    func settingDerivedFrom(_ id: String) -> FolderProfile {
        FolderProfile(profileId: profileId, root: root, folders: folders,
                      personTokens: personTokens, personAliases: personAliases,
                      builtBy: builtBy, derivedFrom: id,
                      unknownRoles: unknownRoles, undecodableFolders: undecodableFolders)
    }
}

public enum RestructureRederive {

    // MARK: - What the manifest moved

    /// The directory-level mappings, in the order they ran — what folder keys re-prefix through.
    /// `rename-dir` and `move-dir` both move a directory; nothing else does.
    public static func renameMap(of manifest: RestructureManifest) -> [(from: String, to: String)] {
        manifest.actions.compactMap { action in
            guard action.action == .renameDir || action.action == .moveDir,
                  let src = action.src, let dst = action.dst else { return nil }
            return (from: src, to: dst)
        }
    }

    /// The file-level mappings — where each moved file actually IS, which is `collidedInto` when
    /// the landing had to pick a unique name (§5.4's collision fact, read here the same way the
    /// inverse reads it).
    public static func fileMoves(of manifest: RestructureManifest) -> [(from: String, to: String)] {
        manifest.actions.compactMap { action in
            guard action.action == .moveFile, let src = action.src,
                  let dst = action.collidedInto ?? action.dst else { return nil }
            return (from: src, to: dst)
        }
    }

    /// The rename list with each step's **child prefix built once**.
    ///
    /// `mapped` is asked about every folder in the profile (`carryOver`, 3,013 of them) and every
    /// document in the corpus (`rekeyedCorpus`, ~9,000) — and it built `rename.from + "/"` inside
    /// that loop, once per path per rename. On a landing with a dozen renames that is a hundred
    /// thousand throwaway strings on the main actor, for a value that depends only on the rename.
    /// Same rule, same order, same answers; the concatenation just moved out of the loop.
    struct RenameSteps {
        /// `from`, its child prefix, and `to` — the child prefix is what says a path sits BENEATH
        /// the renamed folder rather than merely sharing its name's letters (`A/BB` is not under
        /// `A/B`), the same rule ``RestructureStore/rekey(renames:)`` documents.
        let steps: [(from: String, prefix: String, to: String)]

        init(_ renames: [(from: String, to: String)]) {
            steps = renames.map { (from: $0.from, prefix: $0.from + "/", to: $0.to) }
        }

        var isEmpty: Bool { steps.isEmpty }

        /// One path pushed through every step, in order — a later rename may legitimately act on
        /// the product of an earlier one, which is why this is a fold and not a lookup.
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

    /// One path pushed through the directory renames, in order — prefix-aware, and never touching
    /// a sibling that merely shares a name prefix (`A/BB` is not under `A/B`), the same rule
    /// ``RestructureStore/rekey(renames:)`` documents.
    ///
    /// The single-path spelling. A caller mapping MANY paths through the same renames builds a
    /// ``RenameSteps`` once instead — this is that, for one path.
    public static func mapped(_ path: String, through renames: [(from: String, to: String)])
        -> String {
        RenameSteps(renames).mapped(path)
    }

    // MARK: - Step 6: the carry-over

    /// The freshly walked profile with the old one's judgements carried forward: for every path
    /// that exists in both — directly, or through this manifest's renames — `acceptsNewFiles`,
    /// `noIntakeReason` and `naming` are copied from the old entry.
    ///
    /// **Copied when the old entry actually holds one** (non-nil), and left as the walk found
    /// them otherwise: the carry-over exists to preserve judgements a walk cannot see, not to
    /// erase what the walk did see with an old silence. Measured on this machine (§5.5): 45 hand
    /// refusals against the 39 inboxes the walk finds — six judgements that exist nowhere else —
    /// and `naming` on 2,534 entries that the day the rename pass starts reading it must not be
    /// the day it silently stopped existing.
    public static func carryOver(from old: FolderProfile, into fresh: FolderProfile,
                                 through manifest: RestructureManifest) -> FolderProfile {
        let renames = RenameSteps(renameMap(of: manifest))
        var folders = fresh.folders
        // Two old paths can map onto one fresh path — a stale entry recorded at a rename's
        // destination before that folder was hand-deleted, plus the renamed source itself. The
        // winner is decided, not left to dictionary order: the entry that actually travelled
        // through the manifest carries the judgements that belong at the destination; ties
        // break lexicographically.
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

    /// The jurisdiction set a re-derivation walks with — **the distinct entry-level values, never
    /// the header's list** (§5.5, decisions block): the header says `US, IN` while the entries
    /// carry `Singapore` on 10 folders, and taking the header loses the tree an axis value.
    public static func entryJurisdictions(of profile: FolderProfile) -> Set<String> {
        Set(profile.folders.values.compactMap { $0.axes["jurisdiction"] })
    }

    // MARK: - Step 7: the key replay

    /// The corpus with every key moved the way the manifest moved its file — a `rename-dir`
    /// re-prefixes every key beneath it, a `move-file` re-keys one document, a merge re-keys each
    /// file it moved. **The stamps do not move**: a file that only moved was not re-read, which is
    /// the whole point of the replay (§5.5 step 7).
    public static func rekeyedCorpus(_ corpus: FilingCorpus,
                                     through manifest: RestructureManifest) -> FilingCorpus {
        let renames = RenameSteps(renameMap(of: manifest))
        let moves = Dictionary(fileMoves(of: manifest),
                               uniquingKeysWith: { _, second in second })
        var rekeyed: [String: FilingCorpusDocument] = [:]
        rekeyed.reserveCapacity(corpus.documents.count)
        // Two passes so a collision between a MOVED document and a stale key already sitting at
        // its destination (the file there was deleted since the last scan, so the apply saw no
        // collision) resolves the same way every run: the moved claim wins — `carryOver` and
        // `RestructureStore.rekeyedMap` both decide this exact race that way, and this replay
        // was the one sibling leaving it to dictionary iteration order.
        var movedKeys: Set<String> = []
        for (path, document) in corpus.documents {
            // A file move names the document exactly; the directory renames re-prefix the rest.
            // A moved file's SOURCE path is its pre-apply key, so the exact match runs first —
            // the dir map would otherwise re-prefix a merge source's files to a path the merge
            // never used.
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
}
