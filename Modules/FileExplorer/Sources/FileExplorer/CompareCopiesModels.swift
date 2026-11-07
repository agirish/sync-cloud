import Foundation
import Sync
import Design

// MARK: - The facts strip

/// The facts two compared copies differ (or agree) on: name, location, size, modified, and page
/// count when a typed reader can answer for it.
///
/// Pure, built from the scan's own values with no I/O, so the strip renders in the same paint as
/// the surface (`DuplicateCopy` carries every row but pages), and the rule for which rows are
/// emphasised is a value a test can call.
///
/// `differs` compares the underlying values, never the rendered strings: 1,200,000 and 1,200,400
/// bytes both render "1.2 MB", and a strip that diffed its labels would call them equal. Dates are
/// compared the same way, and the modified row shows a time so that two files edited hours apart
/// on one day don't look identical on a row that says they differ.
struct ComparePairFacts: Equatable {

    /// Which fact a row states. A closed set, so the surface can ask for one by name (the
    /// identical-pair variant reads `size` and `modified`) rather than by an index whose order is a
    /// rendering decision.
    enum Field: String, CaseIterable, Equatable {
        case name, location, size, modified, pages
    }

    struct Row: Equatable, Identifiable {
        let field: Field
        /// The row's label, e.g. "Modified".
        let label: String
        let left: String
        let right: String
        /// True when the two sides hold different values — what the strip emphasises.
        let differs: Bool
        /// True while the value is still being resolved: only the page count, which needs the PDF
        /// serial lane and may queue behind a scan. A pending row is neither same nor different.
        let isPending: Bool

        var id: Field { field }
    }

    let rows: [Row]

    /// The fields whose two sides differ. The surface's summary line ("size and date differ") reads
    /// this rather than re-deriving it.
    var differingFields: [Field] { rows.filter { $0.differs && !$0.isPending }.map(\.field) }

    /// The bar's one line about this pair: ``summary(differing:)``, hedged while a row hasn't
    /// answered. `differingFields` excludes pending rows, so with a page count still being read the
    /// plain sentence would say two documents of different lengths match. The claim waits for the
    /// row instead.
    var summary: String {
        let unnamed = differingFields.filter { $0 != .name }
        guard unnamed.isEmpty, rows.contains(where: \.isPending) else {
            return Self.summary(differing: differingFields)
        }
        return "Every fact the scan recorded matches — one is still being read."
    }

    /// Builds the strip for one pair.
    ///
    /// - Parameters:
    ///   - left/right: the two copies, in the order they are drawn.
    ///   - scanRoot/providerName: anchor the location crumbs, with the same derivation as the
    ///     card's breadcrumb (`DuplicateGroupCard.crumbs(of:scanRoot:providerName:)`), so the two
    ///     can't describe one file's home two ways.
    ///   - pages: the two page counts, once a reader has answered. `nil` on either side leaves the
    ///     row pending; `nil` for the pair omits the row (the pair isn't paged).
    static func make(left: DuplicateCopy, right: DuplicateCopy,
                     scanRoot: String?, providerName: String?,
                     pages: (left: Int?, right: Int?)? = nil) -> ComparePairFacts {
        func location(_ copy: DuplicateCopy) -> String {
            let crumbs = DuplicateGroupCard.crumbs(of: copy.path, scanRoot: scanRoot,
                                                   providerName: providerName)
            // The file's own name is the last crumb and already the row above; dropping it leaves
            // the folder, the fact this row states.
            return crumbs.dropLast().joined(separator: " › ")
        }
        var rows: [Row] = [
            Row(field: .name, label: "Name", left: left.name, right: right.name,
                differs: left.name != right.name, isPending: false),
            Row(field: .location, label: "Location",
                left: location(left), right: location(right),
                // Compared on the paths, not the rendered crumbs: two folders can crumb to the
                // same string when one is outside the scan root and gets a tilde path.
                differs: (left.path as NSString).deletingLastPathComponent
                    != (right.path as NSString).deletingLastPathComponent,
                isPending: false),
            Row(field: .size, label: "Size",
                left: FileSyncManager.formatBytes(left.size),
                right: FileSyncManager.formatBytes(right.size),
                differs: left.size != right.size, isPending: false),
            Row(field: .modified, label: "Modified",
                left: dateText(left.modificationDate), right: dateText(right.modificationDate),
                differs: left.modificationDate != right.modificationDate, isPending: false),
        ]
        if let pages {
            let pending = pages.left == nil || pages.right == nil
            rows.append(Row(field: .pages, label: "Pages",
                            left: pageText(pages.left), right: pageText(pages.right),
                            differs: !pending && pages.left != pages.right,
                            isPending: pending))
        }
        return ComparePairFacts(rows: rows)
    }

    /// The `pages:` argument for one pair, from its kind and whatever the page lane has answered.
    ///
    /// Three states, hence an optional tuple of optionals: a pair with no pages omits the row, a PDF
    /// whose counts are in flight leaves it pending, and a PDF that has answered states them. A
    /// locked or unopenable PDF answers 0, a real count; the pane beside it says it couldn't open.
    static func pages(for kind: PairContentKind,
                      pairing: PagePairing?) -> (left: Int?, right: Int?)? {
        guard kind == .pdf else { return nil }
        guard let pairing else { return (left: nil, right: nil) }
        return (left: pairing.leftPages, right: pairing.rightPages)
    }

    /// "12 pages", "1 page", "…" while the lane hasn't answered. A function rather than an
    /// interpolation at the call site, where plural bugs creep in.
    static func pageText(_ count: Int?) -> String {
        guard let count else { return "…" }
        return "\(count) page\(count == 1 ? "" : "s")"
    }

    /// Date and time. A date-only label renders two files edited six hours apart identically, which
    /// would put two equal-looking strings on a row flagged as differing.
    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter = ZoneRefreshedFormatter.localized(date: .medium, time: .short)

    /// The one-line summary over the strip: what actually differs, in the reader's words. Name is
    /// left out even though it is a row: a versions group is made of copies whose names differ, so
    /// that is the premise, not a finding.
    static func summary(differing: [Field]) -> String {
        let interesting = differing.filter { $0 != .name }
        guard !interesting.isEmpty else { return "Every fact the scan recorded matches." }
        let words = interesting.map { field -> String in
            switch field {
            case .location: return "location"
            case .size: return "size"
            case .modified: return "date"
            case .pages: return "page count"
            case .name: return "name"
            }
        }
        return "Differs by \(list(words))."
    }

    /// "a", "a and b", "a, b and c" — an Oxford-less list, matching the app's other prose.
    static func list(_ words: [String]) -> String {
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        case 2: return "\(words[0]) and \(words[1])"
        default: return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
    }
}

// MARK: - The destructive confirmation

/// The wording of the Compare Copies surface's "Trash the Other Copy" confirmation, the last thing
/// read before one of the user's files is destroyed.
///
/// A value for the same reason as ``DuplicateRemovalPrompt``: so a test can hold it to the claim.
/// A same-text group's copy must never be called a *redundant copy*, the identical group's word,
/// which would assert what the group hasn't proved. The noun comes from
/// ``DuplicateRemovalPrompt/itemWord(for:count:)``, so a copy is called the same thing whichever
/// door trashes it.
enum DuplicateComparePrompt {

    /// The longest the informative block may be. It holds because nothing in it is unbounded: the
    /// names are held to ``nameBudget`` and the locations to ``locationBudget``.
    static let lengthBudget = 420

    /// The longest a name may be before it is middle-truncated into the prompt. A question that
    /// wraps to four lines gets skimmed, and file names here run past 60 characters.
    static let nameBudget = 44

    static func messageText(copyName: String) -> String {
        "Move “\(truncated(copyName))” to the Trash?"
    }

    /// What is being destroyed and where it lives, then what survives and where, and for a claim
    /// weaker than byte-identity, what the user is agreeing to.
    ///
    /// The doomed copy's location leads: the reader choosing between two similar copies needs to see
    /// which folder is losing the file. One line per fact, because an `NSAlert`'s informative text
    /// wraps and facts run together don't get separated.
    ///
    /// The `⌘Z` promise is unconditional, as on the card: this is read before the volume is known,
    /// and the engine's banner afterwards carries the real undoability (`DeleteOutcome.isUndoable`
    /// is false on a Trash-less volume). It describes the ordinary case.
    static func informativeText(kind: DuplicateMatchType.Kind,
                                copyName: String,
                                copyLocation: String,
                                keeperName: String,
                                keeperLocation: String,
                                reclaimText: String) -> String {
        var lines: [String] = []
        lines.append("Trashing “\(truncated(copyName))”"
                     + (copyLocation.isEmpty ? "" : "\n\(location(copyLocation))"))
        lines.append("Keeping “\(truncated(keeperName))”"
                     + (keeperLocation.isEmpty ? "" : "\n\(location(keeperLocation))"))
        var closing = "Reclaims \(reclaimText)."
        switch kind {
        case .sameText:
            closing += " These read the same but their bytes differ — a signed or edited copy would "
                + "read the same too."
        case .versions:
            closing += " Versions are genuinely different content, not copies — keep the one you want."
        case .identical, .overlapping:
            break
        }
        lines.append(closing + " This can be undone with ⌘Z.")
        return lines.joined(separator: "\n\n")
    }

    /// The most a location may spend before it is shortened from the front, like the surface's own
    /// location row: the two copies share their leading crumbs, so the tail is what answers "which
    /// folder is losing this file".
    static let locationBudget = 68

    static func location(_ crumbs: String) -> String {
        guard crumbs.count > locationBudget else { return crumbs }
        return "…" + String(crumbs.suffix(locationBudget - 1))
    }

    /// The confirm button's verb. Never "Delete": the ordinary path is a Trash, and the one volume
    /// where it isn't raises its own permanent-delete confirmation afterwards.
    static let confirmTitle = "Move to Trash"

    /// The trash button's own title, derived from the target, not the kind. The keeper is the
    /// reader's to flip, so on a versions pair the target may be the older or the newer copy, and a
    /// title from the kind alone would name the copy being kept.
    ///
    /// `targetIsOlder` is nil when the dates can't order the pair (one is missing, or they are
    /// equal), and the title then says only "the other copy", which is true of every pair.
    static func trashTitle(kind: DuplicateMatchType.Kind, targetIsOlder: Bool?) -> String {
        guard kind == .versions, let targetIsOlder else { return "Trash the Other Copy" }
        return targetIsOlder ? "Trash the Older Copy" : "Trash the Newer Copy"
    }

    /// The same title, from the two copies themselves. What the surface calls, so the ordering that
    /// picks the word is a value a test can drive. `target` is the copy the button would trash;
    /// `keeper` the one it would keep.
    static func trashTitle(kind: DuplicateMatchType.Kind,
                           keeper: DuplicateCopy?, target: DuplicateCopy?) -> String {
        trashTitle(kind: kind, targetIsOlder: targetIsOlder(keeper: keeper, target: target))
    }

    /// Whether the doomed copy is the older of the two, or nil when the dates can't order them: one
    /// is missing, or both carry the same stamp.
    static func targetIsOlder(keeper: DuplicateCopy?, target: DuplicateCopy?) -> Bool? {
        guard let keeperDate = keeper?.modificationDate,
              let targetDate = target?.modificationDate,
              keeperDate != targetDate else { return nil }
        return targetDate < keeperDate
    }

    /// Why the Trash button is unavailable, spelled out rather than left to a greyed control. A copy
    /// inside a folder another group is keeping may never be offered for removal (the
    /// recommendation excludes it too), and a disabled button with no reason looks broken.
    static func disabledReason(copyIsProtected: Bool, copyName: String) -> String? {
        guard copyIsProtected else { return nil }
        return "“\(truncated(copyName))” sits inside a folder another duplicate group is keeping, "
            + "so removing it here would undo that."
    }

    /// Middle-truncation, so the stem and the extension both survive: the end of a name is where
    /// "(1)" and ".pdf" live, which is what tells two copies apart.
    static func truncated(_ name: String) -> String {
        guard name.count > nameBudget else { return name }
        let half = (nameBudget - 1) / 2
        return String(name.prefix(half)) + "…" + String(name.suffix(nameBudget - 1 - half))
    }
}

// MARK: - "Verify now"

/// What a content verification of the two compared copies ended in.
///
/// Three outcomes, because `filesHaveSameContent` collapses them into two: it answers nil when
/// either side can't be hashed (cloud-only, unreadable) or the check was stopped, and none of those
/// means "these files differ". So the surface asks for a ``FileContentVerifier/HashOutcome`` per
/// side and maps the pair here, as a value a test can call.
enum ComparePairVerify: Equatable {
    /// Nothing asked yet.
    case idle
    /// Hashing.
    case running
    /// Both hashed, and the digests match.
    case matched
    /// Both hashed, and the digests differ: the group is stale, and the honest offer is a rescan.
    case differed
    /// At least one side couldn't be hashed. `reason` names which side and why, never "failed".
    case couldNotVerify(reason: String)

    /// Why a side produced no digest: a bare cause, so the sentence can name one side or both. nil
    /// for a hashed side.
    static func cause(_ outcome: FileContentVerifier.HashOutcome) -> String? {
        switch outcome {
        case .hashed: return nil
        case .skippedCloudOnly: return "not downloaded"
        case .unverifiable: return "unreadable, or changed while being read"
        // Never shown: `outcome` answers `.idle` for a stopped check before asking for a cause.
        case .cancelled: return "not checked"
        }
    }

    /// The pair's verdict. Sides are named "left" and "right", for their panes, not by file name,
    /// which in an identical group is the same word twice.
    static func outcome(left: FileContentVerifier.HashOutcome,
                        right: FileContentVerifier.HashOutcome) -> ComparePairVerify {
        // A stopped check learned nothing about either copy, so the surface goes back to how it
        // was: Verify on offer again, no verdict claimed.
        if left == .cancelled || right == .cancelled { return .idle }
        switch (cause(left), cause(right)) {
        case (nil, nil):
            return left.hash == right.hash ? .matched : .differed
        case (let l?, nil):
            return .couldNotVerify(reason: "the left copy is \(l)")
        case (nil, let r?):
            return .couldNotVerify(reason: "the right copy is \(r)")
        case (let l?, let r?):
            return .couldNotVerify(reason: l == r
                ? "both copies are \(l)"
                : "the left copy is \(l); the right copy is \(r)")
        }
    }

    /// The caption the surface prints. One place, so the three outcomes can't drift into two.
    var caption: String {
        switch self {
        case .idle: return ""
        case .running: return "Checking both copies…"
        case .matched: return "Verified: the two files are byte-for-byte identical right now."
        case .differed: return "These are NOT identical any more — the scan is stale. Rescan before removing either."
        case .couldNotVerify(let reason): return "Couldn’t verify: \(reason)."
        }
    }
}

// MARK: - What the pair's match kind actually claims

/// The claim the scan makes about this pair, in the pair's own terms.
///
/// The three kinds claim different things, and only one is "these are the same file". An identical
/// pair was hashed; a same-text pair only reads the same, which a signed or redacted copy also
/// does; a versions pair isn't a copy at all. Showing two previews under one heading would let the
/// weakest claim borrow the strongest one's confidence.
enum ComparePairClaim {

    /// The headline over the two panes, or nil when the kind makes no content claim worth stating
    /// (versions and overlapping: the facts strip already says what differs). `contentUnverified`
    /// weakens the identical claim rather than dropping it: the scan did group these, and silence
    /// would let the reader assume the strong form.
    static func headline(kind: DuplicateMatchType.Kind, contentUnverified: Bool) -> String? {
        switch kind {
        case .identical:
            return contentUnverified
                ? "Grouped as identical, but the scan couldn’t hash one of them (not downloaded, or unreadable) — the claim rests on less than a full check."
                : "The scan hashed both: byte-for-byte identical."
        case .sameText:
            return "These read the same; their bytes differ. A signed, redacted or re-saved copy reads the same too."
        case .versions, .overlapping:
            return nil
        }
    }

    /// Whether the previews will look the same and the useful act is a re-check rather than a read.
    /// Only a byte-identical claim earns that; a same-text pair is exactly the one worth looking at.
    static func offersVerify(kind: DuplicateMatchType.Kind) -> Bool { kind == .identical }
}
