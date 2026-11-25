import Foundation

extension VaultHolders {
    /// `find` as all its documents now say, from `copies` (the number's own, by file), keeping
    /// its id and the user's choices.
    func rebuilt(_ find: VaultFind, from copies: [String: VaultFind]?) -> VaultFind {
        var owner: String?
        if case .person(let id)? = find.assignment { owner = id }
        let parts = split(Array((copies ?? [:]).values), owner: owner)
        guard var merged = VaultModel.merged(parts.own) else { return find }
        merged.facts = VaultHolders.naming(merged.facts, parts.others)
        // Two of the household's people, and nothing to tell whose it is: no one's name, until
        // the person is chosen.
        if parts.unknown {
            merged.facts.holder = nil
            merged.facts.born = nil
            merged.note = ""
        }
        merged.value = find.value
        return merged.keepingChoices(of: VaultChoice(find))
    }
}

extension VaultReadingState {
    /// What a load holds of this sealed reading (VT7 b): this build's rules, `generation`'s read
    /// index, and the household's `people`; and whether it must be sealed again, which it must
    /// when it was read under other rules. The model holds the state as it comes back, and seals
    /// it again as it holds it.
    func opened(generation: Int, people: [Person]) -> (state: VaultReadingState, changed: Bool) {
        var open = self
        open.version = VaultReading.version
        open.generation = generation
        // A Forget since, even one made under older rules: the copies' numbers go with it.
        if self.generation != generation { open.copyNumbers = nil }
        guard version == VaultReading.version else {
            // Another build's rules: read every file again next time. What another build read is
            // let go with it, as its finds were made by older rules; what the user chose about
            // them is carried onto the next read's.
            open.finds = []
            open.mentions = [:]
            open.copies = [:]
            open.read = [:]
            open.choices = choices.merging(Dictionary(
                finds.filter { VaultChoice($0).isChosen }.map { (VaultReading.normalized($0.value), VaultChoice($0)) },
                uniquingKeysWith: { a, _ in a })) { a, _ in a }
            // What another build read IDs from is where Refresh looks first: remembered, though
            // what it read there is let go. Each waiting ID's own document only; its other
            // copies come back with Discover More, which a change of rules offers (VT107, owner).
            var stale = Set(staleSources ?? [])
            stale.formUnion(finds.compactMap { $0.facts.primary?.path })
            open.staleSources = stale.isEmpty ? nil : stale.sorted()
            // Asked for whenever anything read is let go: waiting finds, and also what saved
            // numbers took from their documents (a renewed license's expiry), which a Vault with
            // nothing left to confirm would otherwise lose without a word.
            open.needsReadAgain = needsReadAgain || !(finds.isEmpty && copies.isEmpty && read.isEmpty)
            // Discover More is offered again for the new rules, not for copies.
            open.copiesChanged = nil
            return (open, true)
        }
        // A Forget since: every file is read again next time, its copies too.
        if self.generation != generation { open.read = [:] }
        // Merged by an older build of the same rules: rebuilt, so each names the document it is
        // read from and copies are weighed as they are now.
        let holders = VaultHolders(names: names, people: people)
        open.finds = finds.map { holders.rebuilt($0, from: copies[VaultReading.normalized($0.value)]) }
        return (open, false)
    }
}
