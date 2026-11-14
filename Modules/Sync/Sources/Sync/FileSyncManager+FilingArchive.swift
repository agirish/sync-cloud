import Events
import Foundation

/// New statements for an account that sits in an archive (decision 9): filed there by default,
/// with an offer to move the account out of the archive first, since statements newer than any it
/// holds say the account is live again.
public struct FilingArchiveOffer: Sendable, Equatable {
    /// The account folder now, inside the archive. Absolute.
    public let accountFolder: String
    /// Where it would go: beside the archive, under the same name. Absolute.
    public let target: String
    /// The archive folder's own name, for the button ("Archive", "Closed").
    public let archiveName: String
}

extension FilingDestination {
    /// This home with `old` (a folder) replaced by `new` wherever it begins a path: its own, its
    /// account's and its copies'.
    func repointed(from old: String, to new: String, intoArchive: Bool = false) -> FilingDestination {
        func swap(_ p: String) -> String {
            p == old ? new : (p.hasPrefix(old + "/") ? new + p.dropFirst(old.count) : p)
        }
        func swapAccount(_ a: FilingAccount) -> FilingAccount {
            // Moved, it is in the archive exactly when it moved into one.
            var b = FilingAccount(root: swap(a.root), ending: a.ending, institution: a.institution,
                                  archived: swap(a.root) == a.root ? a.archived : intoArchive, kind: a.kind)
            b.institutionName = a.institutionName
            return b
        }
        var d = FilingDestination(path: swap(path), confidence: confidence, reasons: reasons, newSegments: newSegments,
                                  fromContent: fromContent, remembered: remembered, fromAI: fromAI,
                                  evidenceToken: evidenceToken, neighborMatches: neighborMatches,
                                  proposedName: proposedName, fromSurvey: fromSurvey,
                                  account: account.map(swapAccount), nameOrigin: nameOrigin)
        d.alsoCopiesTo = alsoCopiesTo.map {
            FilingCopy(path: swap($0.path), proposedName: $0.proposedName, account: swapAccount($0.account))
        }
        return d
    }
}

extension FileSyncManager {

    /// The offer for `group`, when it holds two or more statements for an archived account, newer
    /// than the newest it holds, and the folder beside the archive is free. Tax forms and single
    /// files are filed into the archive with no offer.
    public func archiveOffer(for group: FilingCardGroup) -> FilingArchiveOffer? {
        // Asked per render of the card: answered once per set of cards.
        guard group.account.archived else { return nil }
        let key = group.id + "\u{0}" + group.toFile.map(\.filePath).joined(separator: "\u{0}")
        if filingArchiveOfferCache.generation != filingSuggestionsGeneration {
            filingArchiveOfferCache = (filingSuggestionsGeneration, [:])
        }
        if let cached = filingArchiveOfferCache.offers[key] { return cached }
        let offer = computeArchiveOffer(for: group)
        filingArchiveOfferCache.offers[key] = .some(offer)
        return offer
    }

    private func computeArchiveOffer(for group: FilingCardGroup) -> FilingArchiveOffer? {
        let account = group.account
        guard account.archived, group.toFile.count >= 2,
              group.toFile.allSatisfy({ filingDocumentFacts[$0.filePath]?.kind == .statement }),
              let root = filingLastProviderRoot ?? group.members.first?.providerRoot,
              let relative = Self.relativePath(account.root, under: root) else { return nil }
        // The archive: the nearest folder above the account named so, or marked so by the survey.
        var parts = relative.split(separator: "/").map(String.init)
        var archiveIndex: Int?
        for i in stride(from: parts.count - 2, through: 0, by: -1) {
            let path = parts[...i].joined(separator: "/")
            if AccountIndex.isArchiveName(parts[i]) || filingArchivedFolders.contains(path) { archiveIndex = i; break }
        }
        guard let archiveIndex else { return nil }
        let archiveName = parts[archiveIndex]
        // Out of the archive and any year folders it filed the account under (`Archive/2019/…`),
        // keeping the bank folder between (`Archive/HDFC Forex/HDFC Forex 9055`).
        parts.remove(at: archiveIndex)
        while archiveIndex < parts.count - 1, FolderProfileEntry.looksLikeYear(parts[archiveIndex]) {
            parts.remove(at: archiveIndex)
        }
        let target = root + "/" + parts.joined(separator: "/")
        guard !fileManager.fileExists(atPath: target) else { return nil }
        // Newer than anything it holds.
        // Two or more of them newer than anything it holds.
        let periods = group.toFile.compactMap { s in
            filingDocumentFacts[s.filePath]?.period ?? StatementFamily.period(ofName: s.fileName, folder: "")
        }
        guard let node = AccountProposal.node(at: relative, in: filingAccountTaxonomy) else { return nil }
        let held = StatementFamily.families(below: node).values.flatMap { $0 }.map(\.period).max()
        guard periods.filter({ p in held.map { p > $0 } ?? true }).count >= 2 else { return nil }
        return FilingArchiveOffer(accountFolder: account.root, target: target, archiveName: archiveName)
    }

    /// Moves the account out of its archive, points what referred to it at its new place (learned
    /// accounts, the open cards), then files `group` there. One ⌘Z puts the files back and the
    /// account back in the archive. Refuses, moving nothing, when a statement in it is only in the
    /// cloud or the folder beside the archive has been taken since the offer.
    @discardableResult
    public func moveOutOfArchiveThenFile(_ group: FilingCardGroup, offer: FilingArchiveOffer) async -> Int {
        let fm = fileManager
        guard !isVerifyAllRunning, !filingBatchInFlight.contains(ObjectIdentifier(self)) else {
            banner = .refusal("Wait for the filing or Verify All in progress to finish", log: .info)
            return 0
        }
        guard let root = filingLastProviderRoot ?? group.members.first?.providerRoot else { return 0 }
        // Held from here to the end: no other filing starts between the move and the filing.
        filingBatchInFlight.insert(ObjectIdentifier(self))
        defer { filingBatchInFlight.remove(ObjectIdentifier(self)) }
        guard !fm.fileExists(atPath: offer.target) else {
            banner = .refusal("“\((offer.target as NSString).lastPathComponent)” is already beside \(offer.archiveName); filed nothing", log: .info)
            return 0
        }
        let probe = filingHoldsCloudOnlyFile
        let folder = offer.accountFolder
        if await Task.detached(priority: .userInitiated, operation: { probe(folder) }).value {
            banner = .refusal("Some files in “\((offer.accountFolder as NSString).lastPathComponent)” are only in iCloud. Download them first, or file in \(offer.archiveName).", log: .info)
            return 0
        }
        let from = URL(fileURLWithPath: offer.accountFolder), to = URL(fileURLWithPath: offer.target)
        // The bank folder beside the archive may not exist yet (`Archive/Charles Schwab/…`).
        let parents = missingFolders(for: [(offer.target as NSString).deletingLastPathComponent])
        // In the file-operation queue, behind anything already moving files in or out of it.
        let moveError: String? = await enqueueFileOperation {
            do {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: from, to: to)
                return nil
            } catch {
                Self.removeIfEmpty(parents)
                return error.localizedDescription
            }
        }
        if let moveError {
            banner = .refusal("Couldn’t move “\(from.lastPathComponent)” out of \(offer.archiveName): \(moveError)", log: .warn)
            return 0
        }
        filingArchiveOfferCache = (filingSuggestionsGeneration, [:])
        Logger.shared.info("Filing: moved \(from.path) out of \(offer.archiveName) → \(to.path)")
        repointFiling(from: offer.accountFolder, to: offer.target, root: root, intoArchive: false, registersUndo: false)
        let members = group.members.map { s in
            s.replacingCandidates(s.candidates.map { $0.repointed(from: offer.accountFolder, to: offer.target) })
        }
        let moved = FilingCardGroup(account: group.destination.repointed(from: offer.accountFolder, to: offer.target).account ?? group.account,
                                    destination: group.destination.repointed(from: offer.accountFolder, to: offer.target),
                                    members: members)
        // Snapshotted now, before anything is filed into it: what ⌘Z finds once the files are out.
        let prior = PriorFolderMove(move: (from: from, to: to, overwritten: nil),
                                    identityBeforeFiling: ItemIdentity.snapshot(at: to, fileManager: fm),
                                    createdParents: parents, old: offer.accountFolder, new: offer.target, root: root)
        let n = await fileFilingGroup(moved, priorFolderMove: prior, holdsGuard: true)
        if n == 0 {
            // Nothing filed: the account goes back where it was, in the queue, so the move isn't
            // left without a ⌘Z; said so if it can't.
            let back: Bool = await enqueueFileOperation {
                do { try FileManager.default.moveItem(at: to, to: from); Self.removeIfEmpty(parents); return true } catch { return false }
            }
            if back {
                repointFiling(from: offer.target, to: offer.accountFolder, root: root, intoArchive: true, registersUndo: false)
            } else {
                banner = .warning("Filed nothing, and “\(to.lastPathComponent)” couldn’t go back into \(offer.archiveName); it is beside it now", log: .warn)
            }
        }
        return n
    }

    /// Whether any file under `folder` is only in the cloud: moving it then would ask the provider
    /// to move what isn't here.
    nonisolated static func holdsCloudOnlyFile(_ folder: String) -> Bool {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return false }
        while let rel = walker.nextObject() as? String {
            if MaterializationStatus.isCloudOnlyIfKnown(atPath: folder + "/" + rel) == true { return true }
        }
        return false
    }

    /// Learned accounts, the open cards and the account index that point inside `old` now point
    /// inside `new`. `root` is the tree learned accounts are relative to, as it was at the move,
    /// so a scan of another tree since doesn't stop it. `intoArchive`: the folder went into an
    /// archive, so what points at it is archived again.
    func repointFiling(from old: String, to new: String, root: String, intoArchive: Bool, registersUndo: Bool = true) {
        if let oldRel = Self.relativePath(old, under: root), let newRel = Self.relativePath(new, under: root) {
            var learned = filingLearnedAccounts
            var changed = false
            for i in learned.indices where learned[i].surveyRoot == root
                && (learned[i].folder == oldRel || learned[i].folder.hasPrefix(oldRel + "/")) {
                learned[i].folder = newRel + learned[i].folder.dropFirst(oldRel.count)
                changed = true
            }
            if changed { filingLearnedAccounts = learned }
            if filingLastProviderRoot == root, let index = filingAccountIndex {
                let accounts = index.accounts.map { a -> AccountIndex.Account in
                    guard a.root == oldRel || a.root.hasPrefix(oldRel + "/") else { return a }
                    var b = AccountIndex.Account(root: newRel + a.root.dropFirst(oldRel.count), identities: a.identities,
                                                 institution: a.institution, archived: intoArchive)
                    b.institutionName = a.institutionName
                    return b
                }
                filingAccountIndex = AccountIndex(accounts: accounts, institutionTokens: index.institutionTokens,
                                                  genericWords: index.genericWords)
            }
        }
        filingSuggestions = filingSuggestions.map { s in
            s.replacingCandidates(s.candidates.map { $0.repointed(from: old, to: new, intoArchive: intoArchive) })
        }
        filingArchiveOfferCache = (filingSuggestionsGeneration, [:])
        if registersUndo { registerRepointUndo(from: new, to: old, root: root, intoArchive: !intoArchive) }
    }

    /// An undo that points learned accounts and cards from `new` back to `old`, once the folder
    /// is back: queued behind the moves the same ⌘Z queued first, and skipped if the folder
    /// stayed where it was (its move-back refused). Registers its own redo.
    func registerRepointUndo(from new: String, to old: String, root: String, intoArchive: Bool) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerRepointUndo(from: old, to: new, root: root, intoArchive: !intoArchive)
            // The slot is claimed in a task, not here: after every other action of the same ⌘Z
            // or ⇧⌘Z has claimed its own, whichever order they run in, so the folder has moved.
            Task { @MainActor in
                let slot = target.claimFileOperationSlot()
                let back = await target.enqueueFileOperation(slot: slot) {
                    FileManager.default.fileExists(atPath: old) && !FileManager.default.fileExists(atPath: new)
                }
                if back { target.repointFiling(from: new, to: old, root: root, intoArchive: intoArchive, registersUndo: false) }
            }
        }
    }
}
