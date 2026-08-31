import Foundation
import Sync

// MARK: - The facts strip

/// The facts two compared copies differ (or agree) on — name, location, size, modified, and, when
/// a typed reader can answer for it, page count.
///
/// **Pure, and built from the scan's own values with no I/O.** Two things follow from that. The
/// strip renders instantly, in the same paint as the surface it heads — `DuplicateCopy` carries
/// every row here except pages, so nothing waits on a stat. And the rule that decides which rows
/// are *emphasised* is a value a test can call, rather than a colour chosen inside a `body` where
/// nothing could hold it to its claims.
///
/// **`differs` compares the underlying values, never the rendered strings.** A byte count is
/// formatted to three significant figures, so 1,200,000 and 1,200,400 both render "1.2 MB" — a
/// strip that diffed its own labels would call those equal, at the top of a surface whose whole
/// job is to say whether two files are the same. The dates are compared the same way, which is
/// also why the modified row renders a TIME: two files edited six hours apart on one day are a
/// difference the reader has to be able to see, and a date-only label hides it behind a row that
/// says "differs".
struct ComparePairFacts: Equatable {

    /// Which fact a row states. A closed set, so the surface can ask for one by name (the
    /// identical-pair variant reads `size` and `modified`) instead of indexing into an array whose
    /// order is a rendering decision.
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
        /// True while the value is still being resolved (only ever the page count, which needs the
        /// PDF serial lane and may be queued behind a scan). A pending row claims nothing: it is
        /// neither the same nor different until it answers.
        let isPending: Bool

        var id: Field { field }
    }

    let rows: [Row]

    /// The fields whose two sides differ — the surface's summary line ("size and date differ")
    /// reads this rather than re-deriving it.
    var differingFields: [Field] { rows.filter { $0.differs && !$0.isPending }.map(\.field) }

    /// Whether every resolved row agrees. Deliberately excludes pending rows, so a page count that
    /// has not arrived cannot make a pair look identical.
    var everyResolvedRowAgrees: Bool {
        rows.allSatisfy { $0.isPending || !$0.differs }
    }

    /// Builds the strip for one pair.
    ///
    /// - Parameters:
    ///   - left/right: the two copies, in the order they are drawn.
    ///   - scanRoot/providerName: how the location crumbs are anchored — the same derivation the
    ///     card's breadcrumb uses (`DuplicateGroupCard.crumbs(of:scanRoot:providerName:)`), so the
    ///     two surfaces cannot describe one file's home two ways.
    ///   - pages: the two page counts, when a reader has answered. `nil` on either side leaves the
    ///     row pending; passing `nil` for the pair omits the row entirely (the pair is not paged).
    static func make(left: DuplicateCopy, right: DuplicateCopy,
                     scanRoot: String?, providerName: String?,
                     pages: (left: Int?, right: Int?)? = nil) -> ComparePairFacts {
        func location(_ copy: DuplicateCopy) -> String {
            let crumbs = DuplicateGroupCard.crumbs(of: copy.path, scanRoot: scanRoot,
                                                   providerName: providerName)
            // The file's own name is the last crumb and is already the row above; dropping it
            // leaves the folder, which is the fact this row exists to state.
            return crumbs.dropLast().joined(separator: " › ")
        }
        var rows: [Row] = [
            Row(field: .name, label: "Name", left: left.name, right: right.name,
                differs: left.name != right.name, isPending: false),
            Row(field: .location, label: "Location",
                left: location(left), right: location(right),
                // Compared on the PATHS, not on the rendered crumbs: two folders can crumb to the
                // same string when one of them is outside the scan root and gets a tilde path.
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

    /// "12 pages", "1 page", "…" while the lane has not answered. A static func rather than an
    /// interpolation at the call site, because that is where this app's plural bugs live.
    static func pageText(_ count: Int?) -> String {
        guard let count else { return "…" }
        return "\(count) page\(count == 1 ? "" : "s")"
    }

    /// Date AND time. A `.medium`/`.none` label renders two files edited six hours apart
    /// identically, which would put two equal-looking strings on a row flagged as differing.
    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// The one-line summary over the strip: what actually differs, in the reader's words.
    ///
    /// Name is deliberately excluded from the *summary* even though it is a row: a versions group
    /// is built out of copies whose names differ, so "the names differ" is the premise rather than
    /// a finding. The row still shows it.
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

/// The wording of the Compare Copies surface's "Trash the other copy" confirmation — the last
/// thing read before one of the user's files is destroyed.
///
/// Here for the reason ``DuplicateRemovalPrompt`` is here: this vocabulary has drifted before. The
/// card is careful about a same-text group — an unfilled seal, "bytes differ", a note asking the
/// user to open both documents first — and the confirmation then called the other file a *redundant
/// copy*, the identical group's word, asserting the very thing the group has not proved, at the
/// point of no return. Composed inline in a view it was also untestable, which is why it went
/// unnoticed for as long as it did.
///
/// The noun comes from ``DuplicateRemovalPrompt/itemWord(for:count:)`` rather than a second table
/// of the same words: one file group's copy is called the same thing whichever door trashes it.
enum DuplicateComparePrompt {

    /// The longest the informative BLOCK may be. It means something because nothing in it is
    /// unbounded: the two names are held to ``nameBudget`` and the two locations to
    /// ``locationBudget``.
    static let lengthBudget = 420

    /// The longest a name may be before it is middle-truncated into the prompt. A dialog whose
    /// question wraps to four lines is one the reader skims, and file names in this tree run past
    /// 60 characters.
    static let nameBudget = 44

    static func messageText(copyName: String) -> String {
        "Move “\(truncated(copyName))” to the Trash?"
    }

    /// What is being destroyed and where it lives, then what survives and where — and, for a claim
    /// weaker than byte-identity, what the user is actually agreeing to.
    ///
    /// **The doomed copy's LOCATION leads, and that is a correction.** This used to open "Keeps
    /// “Car Lease.pdf” at …" — naming the survivor's path and never the victim's. His report: it
    /// should say which file is being deleted, with its path. The title names the file; a reader
    /// about to destroy one of two identically-sized copies with similar names needs to see WHICH
    /// FOLDER is losing it, and that was the one fact the dialog withheld.
    ///
    /// Line-per-fact rather than a paragraph: an `NSAlert`'s informative text wraps, and three
    /// facts run together are three facts nobody separates at the point of no return.
    ///
    /// The `⌘Z` promise is unconditional here for the same reason the card's is: the engine posts
    /// the banner that carries the *real* undoability (`DeleteOutcome.isUndoable` is false on a
    /// Trash-less volume), and this sentence is read BEFORE the volume is known. It says what the
    /// ordinary case does; the banner afterwards is what promises the shortcut.
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

    /// The most a location may spend before it is shortened from the FRONT.
    ///
    /// Head-truncated, like the surface's own location row and for the same reason: the two copies
    /// share their leading crumbs and differ in the trailing ones, so the tail is the part that
    /// answers "which folder is losing this file".
    static let locationBudget = 68

    static func location(_ crumbs: String) -> String {
        guard crumbs.count > locationBudget else { return crumbs }
        return "…" + String(crumbs.suffix(locationBudget - 1))
    }

    /// The confirm button's verb. Never "Delete": the ordinary path is a Trash, and the one volume
    /// where it is not raises its own permanent-delete confirmation afterwards.
    static let confirmTitle = "Move to Trash"

    /// Why the Trash button is unavailable, spelled out rather than left to a greyed control. A
    /// copy inside a folder another group is KEEPING may never be offered for removal — the
    /// recommendation excludes it for the same reason — and a disabled button with no reason reads
    /// as the app being broken.
    static func disabledReason(copyIsProtected: Bool, copyName: String) -> String? {
        guard copyIsProtected else { return nil }
        return "“\(truncated(copyName))” sits inside a folder another duplicate group is keeping, "
            + "so removing it here would undo that."
    }

    /// Middle-truncation, so both the stem and the extension survive — the end of a file name is
    /// where "(1)" and ".pdf" live, which is exactly what tells two copies apart.
    static func truncated(_ name: String) -> String {
        guard name.count > nameBudget else { return name }
        let half = (nameBudget - 1) / 2
        return String(name.prefix(half)) + "…" + String(name.suffix(nameBudget - 1 - half))
    }
}

// MARK: - "Verify now"

/// What a content verification of the two compared copies ended in.
///
/// **Three distinct outcomes, because `filesHaveSameContent` collapses them into two.** It returns
/// `Bool?` and answers nil when *either* side cannot be hashed — over the 100 MB cap, cloud-only,
/// unreadable — three different situations, none of which is "these files differ" and none of
/// which the surface may flatten into a generic failure. So the surface asks for a
/// ``FileContentVerifier/HashOutcome`` per side and maps the pair here, where the mapping is a
/// value a test can call.
enum ComparePairVerify: Equatable {
    /// Nothing asked yet.
    case idle
    /// Hashing.
    case running
    /// Both hashed, and the digests match.
    case matched
    /// Both hashed, and the digests differ — the group is stale, and the honest offer is a rescan.
    case differed
    /// At least one side could not be hashed. `reason` names WHICH side and WHY, never "failed".
    case couldNotVerify(reason: String)

    /// Why a side produced no digest — a bare cause, so the sentence can name one side or both.
    /// nil for a hashed side.
    static func cause(_ outcome: FileContentVerifier.HashOutcome) -> String? {
        switch outcome {
        case .hashed: return nil
        case .skippedTooLarge:
            return "over the \(FileContentVerifier.maxBytesToHash / (1024 * 1024)) MB verify limit"
        case .skippedCloudOnly: return "not downloaded"
        case .unverifiable: return "unreadable, or changed while being read"
        }
    }

    /// The pair's verdict. Sides are named "left"/"right" — the panes they sit in — rather than by
    /// file name, which in an identical group is the same word twice.
    static func outcome(left: FileContentVerifier.HashOutcome,
                        right: FileContentVerifier.HashOutcome) -> ComparePairVerify {
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

    /// The caption the surface prints. One place, so the three outcomes cannot drift into two.
    var caption: String {
        switch self {
        case .idle: return ""
        case .running: return "Checking both copies…"
        case .matched: return "Verified: the two files are byte-for-byte identical right now."
        case .differed: return "These are NOT identical any more — the scan is stale. Rescan before removing either."
        case .couldNotVerify(let reason): return "Couldn't verify: \(reason)."
        }
    }
}

// MARK: - What the pair's match kind actually claims

/// The claim the scan makes about this pair, in the pair's own terms — CC4's honesty rule, as a
/// value.
///
/// **The point is that the three kinds claim three different things, and only one of them is
/// "these are the same file".** An identical pair was hashed; a same-text pair was proved to *read*
/// the same, which the measured signed-copy and redacted-copy cases show is not the same as being
/// the same document; and a versions pair is not a copy at all. A surface that showed two previews
/// under one heading would let the weakest claim borrow the strongest one's confidence.
enum ComparePairClaim {

    /// The headline over the two panes. nil when the kind makes no content claim worth stating
    /// (versions and overlapping — the facts strip already says what differs).
    ///
    /// `contentUnverified` weakens the identical claim rather than deleting it: the scan DID group
    /// these, and saying nothing would leave the reader to assume the strong form.
    static func headline(kind: DuplicateMatchType.Kind, contentUnverified: Bool) -> String? {
        switch kind {
        case .identical:
            return contentUnverified
                ? "Grouped as identical, but the scan couldn't hash one of them (too large, or not downloaded) — the claim rests on less than a full check."
                : "The scan hashed both: byte-for-byte identical."
        case .sameText:
            return "These read the same; their bytes differ. A signed, redacted or re-saved copy reads the same too."
        case .versions, .overlapping:
            return nil
        }
    }

    /// Whether the pair is one where the previews will look the same and the useful act is a
    /// re-check rather than a read. Only a byte-identical claim earns that — a same-text pair is
    /// exactly the pair worth looking at.
    static func offersVerify(kind: DuplicateMatchType.Kind) -> Bool { kind == .identical }
}
