import Foundation

// What a row says in the panel (VT8): its title and line under it, the detail's lede, its
// kind's name and note, its number's label, and what VoiceOver says of it. Pure, so each is
// tested with literal values; the panel only lays them out. Moved from `VaultCard` unchanged.

extension VaultModel.Row {
    /// Whose it is, and which one when a person has more than one of a kind.
    public var listTitle: String {
        let row = self
        if row.isTypedIn { return row.title }
        // Whose, when a name was read; then what tells this one apart from others of its kind.
        let whose = row.personID != nil || row.facts?.holder != nil ? row.whose : nil
        let which = row.category.spec.which(row.facts, row.title, whose)
        let parts = [whose, which].compactMap { $0 }
        return parts.isEmpty ? row.category.singular : parts.joined(separator: " · ")
    }

    /// What tells it apart at a glance: when it runs out or why it is in Archive, and its files.
    public func listSubtitle(now: Date) -> String {
        let row = self
        var parts: [String] = []
        if row.isTypedIn {
            parts.append(row.whose)
            if !row.note.isEmpty { parts.append(row.note) }
            parts.append("Typed in")
            return parts.joined(separator: " · ")
        }
        if let reason = row.standing.reason, row.standing.tab == .archive {
            parts.append(reason)
        } else if let until = row.facts?.validUntil {
            let word = row.category.spec.goodUntil ?? (VaultReading.hasRunOut(until, now: now) ? "Expired" : "Valid to")
            parts.append("\(word) \(VaultReading.monthYear(until))")
        } else if let dated = row.facts?.dated {
            parts.append(VaultReading.monthYear(dated))
        }
        // How many documents carry it is in its details, which list them.
        return parts.joined(separator: " · ")
    }

    public var detailLede: String {
        let row = self
        var parts = [row.headingName]
        // Why it is in Archive is the Tab row's caption, so it isn't said twice.
        if !row.isSaved, row.standing.tab != .archive { parts.append("To confirm") }
        return parts.joined(separator: " · ")
    }

    /// A row's title under its person's name: what the ID is, as its details call it.
    public var kindTitle: String {
        let row = self
        return row.isTypedIn ? row.title : row.title.replacingOccurrences(of: " case", with: "")
    }

    /// Why an ID is on the card it is, when not as read: never lost from sight. The folder's
    /// name is masked unless its ID is `shown`, as the documents list masks it (the final review).
    public func kindNote(shown: Bool) -> String? {
        let row = self
        if let folder = row.learnedFrom {
            return "Learned from your choice for “\(lessonFolderName(folder, shown: shown))”"
        }
        guard row.card != .builtIn(row.readAs) else { return nil }
        return "\(row.isTypedIn ? "Typed in" : "Read") as \(row.readAs.title)"
    }

    /// A lesson folder's own name, masked unless its ID is `shown`: a folder may be named after
    /// the number.
    public func lessonFolderName(_ folder: String, shown: Bool) -> String {
        let name = (folder as NSString).lastPathComponent
        return shown ? name : VaultMask.folder(name, keep: VaultMask.keep(for: category))
    }

    /// What the ID in Large Type is called, as its document calls it; the heading above already
    /// says what the document is, so this never repeats it ("Passport" over "Passport").
    public var idLabel: String {
        category.spec.idLabel(facts, title)
    }

    /// A row as VoiceOver reads it: what it is, its ending, and the badges the eye sees; `also`,
    /// the ones the panel works out itself ("Updated", "Expires in 12 days"), said lowercased.
    public func spoken(title: String, also: [String] = []) -> String {
        let row = self
        var parts = [title, row.category.singular, VaultMask.spoken(row.value, shown: false, hidesEnding: row.category.hidesEnding)]
        parts += also.map { $0.lowercased() }
        if row.documentMissing { parts.append("file not found") }
        if row.standing.inUse { parts.append("in use") }
        if row.standing.expired { parts.append("expired") }
        if row.standing.pending { parts.append("pending") }
        parts.append(row.isSaved ? "in Vault" : row.standing.tab == .archive ? "older" : "to confirm")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A folded card's one line: "3 people · 1 expired · 2 to confirm".
    public static func foldedSummary(_ rows: [VaultModel.Row]) -> String {
        let people = Set(rows.map { $0.personID ?? $0.whose }).count
        let expired = rows.filter(\.standing.expired).count
        let waiting = rows.filter { !$0.isSaved && $0.standing.tab != .archive }.count
        var parts = [people == 1 ? "1 person" : "\(people) people"]
        if expired > 0 { parts.append("\(expired) expired") }
        if waiting > 0 { parts.append("\(waiting) to confirm") }
        return parts.joined(separator: " · ")
    }
}

extension VaultModel.Row {
    /// Large Type's heading: whose it is, then what it is.
    public var largeTypeHeading: String { "\(headingName) · \(title)" }

    /// Whose an ID is, as its headings name them: the household, else the name its document
    /// prints, else the person it was given to. Not ``VaultEntry/holderName``, a name typed over
    /// the document's.
    var headingName: String { isHousehold ? "Household" : (facts?.holder ?? whose) }
}

extension VaultModel {
    /// Whether the panel draws an ID in full, which keeps its window out of screen sharing: the
    /// panel's rule, apart from the view so a test can ask it.
    public func drawsAnIDInFull(layout: VaultLayout, editing: Bool) -> Bool {
        let model = self
        // The editor draws a number in full whatever the lock says: one typed into Add while the
        // Vault is locked, or an ID being edited "For every ID" whose row the list no longer
        // selects (the final review).
        if editing { return true }
        guard model.contents == .loaded else { return false }
        if layout == .people,
           model.peopleSections.contains(where: { !$0.births.isEmpty && model.canShowBirth(in: $0) }) { return true }
        if model.isOpen { return model.selectedRow != nil }
        return model.selection.map { model.lock.canShow($0, at: model.now) } ?? false
    }
}

extension VaultMask {
    /// What VoiceOver says of the number: each character apart while shown, so it is spelled out
    /// rather than read as one large number; its last four while hidden.
    public static func spoken(_ value: String, shown: Bool, hidesEnding: Bool = false) -> String {
        let plain = VaultReading.normalized(value)
        guard shown else {
            // A kind whose ending is itself a secret is not spoken either.
            return plain.count > 4 && !hidesEnding ? "ending \(plain.suffix(4).map(String.init).joined(separator: " "))" : ""
        }
        return plain.map(String.init).joined(separator: " ")
    }
}

extension VaultAssignment {
    /// The editor's Belongs To, as one value for its picker.
    public static func tag(_ assignment: VaultAssignment?) -> String {
        switch assignment {
        case .person(let id)?: return "person:" + id
        case .household?: return "household"
        case nil: return "document"
        }
    }
}
