import Design
import SwiftUI
import Sync

/// §5.4's plan surface: choose the target shape, edit the family mapping, watch the derived
/// operations — and `Export plan…`, which is this milestone's stopping point (the Apply that
/// lands a manifest is §5.5's).
///
/// The sheet owns no derivation logic: every operation it shows comes from
/// ``RestructurePlanner`` on each edit, so what the review section lists IS what the exported
/// manifest carries — there is no second implementation to drift.
struct RestructurePlanSheet: View {
    let finding: StructureFinding
    /// The parent the mapping's members are children of — **an input, not `finding.family`.**
    ///
    /// For a shape finding the two are the same. For a pair seeded through
    /// ``RestructurePlanRoute/seededMapping(family:member:source:target:)`` the family is the
    /// pair's *grandparent* and the single member is the folder they sit in, because the
    /// mapping's unit is a child name inside a member. Reading `finding.family` here would have
    /// pointed the planner one level too shallow on exactly those findings.
    let family: String
    /// Every member of the family — scheme members, drift and shapeless alike: the mapping is
    /// applied to all of them, and drift is the part that most needs housing.
    let members: [String]
    /// The tree as it stands now — disk-backed in the app, dictionary-backed in tests.
    let tree: RestructureTreeView
    let profileId: String
    let accent: Color
    /// A saved draft's rows, so *Review N operations* reopens the plan as it was left.
    var initialRows: [RestructureMapping.Row]?
    /// The saved draft's full picker vocabulary — names the last session could choose from,
    /// including ones no row uses. Without it a reopened draft rebuilt the vocabulary from the
    /// rows' targets alone, so every unused choice vanished and "reopens the plan as it was
    /// left" was false. nil (an older draft, or no draft) falls back to the rows' targets.
    var initialVocabulary: [String]?
    /// Writes the export file and saves the draft. The success case carries the file name the
    /// STORE chose — the footer used to re-derive it from the same recipe, which is two copies
    /// of a name that must match, and the copy in the store is the one on disk.
    enum ExportResult: Equatable {
        case saved(filename: String)
        case failed(String)
    }
    /// Writes the file and the draft; the vocabulary rides along so the draft can reopen with
    /// the same choices on its pickers.
    let onExport: (RestructureManifest, _ vocabulary: [String]) -> ExportResult
    /// §5.5's landing: runs the eight-step apply and returns its outcome sentence — the summary
    /// on success (prefixed so the sheet can tell), or the refusal. nil while Apply is not
    /// offered, which hides the button rather than promising a landing that cannot run.
    var onApply: ((RestructureManifest) async -> ApplyResult)?
    /// §5.6's paid pass — on the MAPPING, never on the apply. nil when the host has not wired a
    /// transport; whether a key is stored is `refineOffered`'s separate question, the same split
    /// the filing refine button documents.
    var onRefineMapping: ((MappingRefineRequest) async -> FileSyncManager.MappingRefineOutcome)?
    /// Is a key stored — the offer/invitation branch (`filingCloudRefineAvailable`'s answer).
    var refineOffered: Bool = false
    /// The model the button names, resolved the way the transport resolves it so the button
    /// cannot name one model and send another.
    var refineModelLabel: String = "Claude"
    /// Opens Settings on the key row — the invitation's action.
    var onConfigureRefine: (() -> Void)?
    /// Where the landing has got to, while it runs — nil at every other moment. Fed straight
    /// from the manager's published value, so the checklist below can only show stages the
    /// engine actually reached.
    var applyProgress: RestructureApplyProgress?

    /// What a landing came back with — the summary, or the sentence that refused it.
    enum ApplyResult: Equatable {
        case applied(summary: String)
        case refused(String)
    }
    let onClose: () -> Void

    @State private var rows: [RestructureMapping.Row] = []
    @State private var vocabulary: [String] = []
    /// Every distinct child name across the family, disk-cased — the rows' sources, and the
    /// spelling authority when a scheme's lowercased vocabulary becomes target names.
    @State private var allSources: [String] = []
    /// Sibling families sharing this one's vocabulary (§5.4 step 2's pointer). Resolved once at
    /// open — it walks every sibling's members, and the tree does not move under a modal sheet.
    @State private var parallelFamilies: [String] = []
    @State private var chosenScheme: Int?
    @State private var customName = ""
    /// Narrows the mapping's VIEW, never its rows — see `mappingSection`.
    @State private var filterText = ""
    @State private var outcome: Outcome?
    @State private var createdAt = ""
    @State private var manifestId = ""

    private enum Outcome: Equatable {
        case exported(String)
        case applied(String)
        case failed(String)
    }

    @State private var applying = false
    @State private var includeFileSamples = false
    @State private var refining = false
    @State private var refineTask: Task<Void, Never>?
    @State private var proposals: [MappingRefineProposal]?
    @State private var refineFailedText: String?

    var body: some View {
        // Derived ONCE per render and handed down. The margin renders per row, and a version
        // that re-derived inside it ran the whole planner — disk listings included — once per
        // row per render; 24 rows made that a couple of hundred directory reads per keystroke.
        let plan = derived
        return VStack(alignment: .leading, spacing: 14) {
            header
            // The editing surface locks as one piece — scheme radios, custom names, pickers
            // and the refine section all go quiet while an apply runs and stay quiet once it
            // lands. The review and footer manage their own states (`refineSection` handles
            // its in-flight Stop itself; `locked` does not include `refining`).
            Group {
                shapeSection
                mappingSection(plan)
                refineSection
            }
            .disabled(locked)
            reviewSection(plan)
            if let applyProgress { progressChecklist(applyProgress) }
            footer(plan)
        }
        .padding(18)
        .frame(width: 620)
        .frame(minHeight: 460)
        .onAppear(perform: seed)
        .onChange(of: rows) {
            // An edit after an export describes a NEW plan; the old outcome sentence would be
            // claiming this one was exported. Guarded on applied as a belt to the editor
            // lockdown's braces: clearing an APPLIED outcome un-retires the whole sheet —
            // Done reverts to Cancel and Export re-arms over operations that already ran.
            guard !isApplied else { return }
            outcome = nil
        }
        .onChange(of: vocabulary) {
            // A vocabulary edit is part of the draft an export saved (the picker choices ride
            // in it), so the "Exported as …" sentence stops being true the moment it changes.
            // An applied outcome stays: vocabulary edits cannot reach a landed plan.
            if case .exported = outcome { outcome = nil }
        }
    }

    /// One seam for "this sheet is finished or busy": the whole editing surface reads it, not
    /// just the footer buttons. Without it, any row edit after a successful Apply cleared the
    /// outcome, un-retired the sheet, and re-armed Export — which then minted a "Planned, not
    /// applied" draft over a reorganisation that had already landed; and edits mid-apply left
    /// the footer's "Applied — …" summary above a derivation re-read from the edited rows.
    private var locked: Bool { applying || isApplied }

    // MARK: - Seeding

    private func seed() {
        guard rows.isEmpty else { return }
        let sources = RestructurePlanner.distinctSources(family: family,
                                                         members: members, in: tree)
        allSources = sources
        // Only for a family mapping. On a seeded pair `family` is the pair's grandparent, so
        // this compared a folder the sheet is not planning and printed its name in a warning
        // about "planning together" — a pointer at the wrong thing is worse than none.
        parallelFamilies = isSeededPair
            ? []
            : RestructurePlanner.parallelFamilies(of: family, in: tree)
        if let initialRows {
            // The draft's rows, reconciled against the sources as they stand now: a source that
            // appeared since the draft gets a fresh keep row; one that vanished drops off.
            let saved = Dictionary(initialRows.map { ($0.source, $0) },
                                   uniquingKeysWith: { first, _ in first })
            rows = Self.adjacentOrder(sources.map { saved[$0] ?? RestructureMapping.Row(source: $0) })
            // The draft's saved vocabulary first (unused choices included), then any target a
            // row uses that it somehow lacks — a picker must always offer the row's own value.
            var restored = initialVocabulary ?? []
            for target in orderedTargets(of: rows) where !restored.contains(target) {
                restored.append(target)
            }
            vocabulary = restored
        } else {
            // Default keep on every row — the editor never guesses a mapping (§5.4 step 3).
            rows = Self.adjacentOrder(sources.map { RestructureMapping.Row(source: $0) })
        }
        let stamp = Self.stamp(Date())
        createdAt = stamp
        manifestId = "plan-\(finding.kind.rawValue)-\(stamp)"
    }

    private func orderedTargets(of rows: [RestructureMapping.Row]) -> [String] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let target = row.target, seen.insert(target).inserted else { return nil }
            return target
        }
    }

    // MARK: - Header

    /// True when this sheet was opened on a PAIR seeded into one member rather than on a whole
    /// family. The mapping machinery is the same; three affordances around it are not, because
    /// they are all about reconciling siblings and there are no siblings here.
    private var isSeededPair: Bool { members.count == 1 }

    /// What this sheet is planning, in one spelling — the header, the manifest's recorded family,
    /// the refine request and the merge margins all read it. For a family mapping it is the
    /// family; for a seeded pair it is the member's own path, because the family is that folder's
    /// parent and can be the empty string.
    private var planFamily: String { Self.headerPath(family: family, members: members) }

    /// Above this many rows the filter appears. Twelve is where a list stops being scannable —
    /// the flagship family has 24 — and below it a filter is a control that costs more than the
    /// scrolling it saves.
    static let filterAppearsAbove = 12

    /// How many rows would change something, out of how many there are. The editor's default is
    /// keep, so "9 of 24 mapped" is the difference between a plan half-made and one deliberately
    /// left mostly alone.
    static func mappedCount(_ rows: [RestructureMapping.Row]) -> String {
        let mapped = rows.filter { row in
            guard let target = row.target else { return false }
            return target != row.source
        }.count
        return "\(mapped) of \(rows.count) mapped — the rest keep their name"
    }

    /// Whether a row survives the filter. Case- and punctuation-insensitive, because the names
    /// this searches are exactly the ones that differ by punctuation: typing `w2` has to find
    /// `Form W-2`, which is the pair the editor exists to reconcile.
    static func matches(_ source: String, filter: String) -> Bool {
        let needle = similarKey(filter)
        guard !needle.isEmpty else { return true }
        return similarKey(source).contains(needle)
    }

    /// A name reduced to what makes two spellings the SAME name — lowercased, stripped of
    /// everything but letters and digits, with a trailing plural folded away.
    ///
    /// Deliberately a plain tokenizer rather than a regex: Swift's `\b` is a Unicode word
    /// boundary and NFC normalisation is implicit, so a regex here would answer differently for
    /// composed and decomposed spellings of the same folder name.
    static func similarKey(_ name: String) -> String {
        var key = name.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        // Fold a trailing plural, but only when a real stem is left. `Bus` reduced to `bu`
        // matched a folder actually called `Bu`, which is the fold inventing a pair rather than
        // finding one — and this editor's whole job is deciding that two names are one.
        if key.count >= 4, key.hasSuffix("s") { key.removeLast() }
        return key
    }

    /// The rows in the order the editor shows them: near-identical names adjacent, so the choice
    /// between `Payment` and `Payments` is made in one place instead of twelve rows apart.
    /// Within a group and between groups the order is the disk's own, so nothing else moves.
    static func adjacentOrder(_ rows: [RestructureMapping.Row]) -> [RestructureMapping.Row] {
        var firstSeen: [String: Int] = [:]
        for (index, row) in rows.enumerated() where firstSeen[similarKey(row.source)] == nil {
            firstSeen[similarKey(row.source)] = index
        }
        return rows.enumerated().sorted { left, right in
            let leftGroup = firstSeen[similarKey(left.element.source)] ?? left.offset
            let rightGroup = firstSeen[similarKey(right.element.source)] ?? right.offset
            if leftGroup != rightGroup { return leftGroup < rightGroup }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// True when this row shares its similar-key with another — the quiet marker that says why
    /// two rows are neighbours.
    static func hasSimilarNeighbour(_ row: RestructureMapping.Row,
                                    in rows: [RestructureMapping.Row]) -> Bool {
        let key = similarKey(row.source)
        return rows.contains { $0.source != row.source && similarKey($0.source) == key }
    }

    /// The folder this mapping runs over, as the header names it.
    ///
    /// A family mapping covers many members, so the family path is the subject. A **seeded pair**
    /// has exactly one member — the folder the two names sit in — and the family is that folder's
    /// parent, which for a top-level pair is the empty string. Naming the member's own path is
    /// both more useful and the only spelling that is never blank.
    static func headerPath(family: String, members: [String]) -> String {
        guard members.count == 1 else { return family }
        return (family as NSString).appendingPathComponent(members[0])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(planFamily)
                .scaledFont(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Text(isSeededPair
                 ? "One mapping for this folder — the operations below are derived from it, "
                    + "never typed."
                 : "One mapping, edited once, applied to every member — the operations below "
                    + "are derived from it, never typed.")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
            if !parallelFamilies.isEmpty {
                // §5.4 step 2's warning as a pointer: the 6 Aug fix was found by laying the
                // sibling families side by side, and a plan for one alone can leave the others
                // disagreeing with it.
                Text("Shares its vocabulary with \(parallelFamilies.joined(separator: ", ")) — "
                     + "a shape chosen here alone may leave them disagreeing. Worth planning "
                     + "together.")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


    // MARK: - 1. The target shape

    @ViewBuilder
    private var shapeSection: some View {
        // A pair carries no schemes — the detectors never set them — so on that route this
        // section rendered its label over nothing but the free-text field. The field itself
        // stays: naming a target the tree has not got is exactly what a rename needs.
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(isSeededPair ? "Target name" : "Target shape")
            // Nothing pre-selected: neither recency nor majority is the authority — the 6 Aug
            // fix went both ways at once, for a reason that existed nowhere in the tree.
            ForEach(Array(finding.schemes.enumerated()), id: \.offset) { index, scheme in
                schemeChoice(index: index, scheme: scheme)
            }
            if Self.newestMembersAreDrift(finding) {
                Text("The newest folders here are drift sharing no scheme — there is no current "
                     + "shape, and that is the finding rather than a failure to name one.")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TextField("Name it myself — add a folder name", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.system(size: 11))
                    .frame(width: 260)
                    .onSubmit(addCustomName)
                Button("Add") { addCustomName() }
                    .scaledFont(.system(size: 11))
                    .disabled(!canAddCustomName())
            }
            if !customName.trimmingCharacters(in: .whitespaces).isEmpty,
               !RestructurePlanner.isValidTargetName(customName) {
                // Why Add is grey, said where the typing happens: a target is ONE folder name,
                // and a path-shaped one would aim a rename outside the family.
                Text("One folder name — no /, no :, no dot traversal.")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func schemeChoice(index: Int, scheme: StructureFinding.Scheme) -> some View {
        Button {
            chosenScheme = index
            // The detector lowercases its vocabulary for comparison; target names take the
            // disk-cased spelling the family actually uses — the scaffold's own casing rule.
            // Typed names SURVIVE a scheme change. Replacing the vocabulary wholesale discarded
            // whatever the user had added, silently, from every picker except the one row already
            // pointing at it — losing input they cannot get back without retyping it.
            let chosen = scheme.vocabulary.map { word in
                allSources.first { $0.lowercased() == word } ?? word.localizedCapitalized
            }
            let typed = vocabulary.filter { name in
                !allSources.contains(name) && !chosen.contains(name)
            }
            vocabulary = chosen + typed
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chosenScheme == index ? "largecircle.fill.circle" : "circle")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(chosenScheme == index ? accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(scheme.vocabulary.joined(separator: " · "))
                            .scaledFont(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if let label = Self.schemeLabel(index: index, in: finding) {
                            Text(label)
                                .scaledFont(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(scheme.members.joined(separator: ", "))
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        // The chosen state otherwise lives only in an SF-symbol swap — invisible to VoiceOver.
        .accessibilityAddTraits(chosenScheme == index ? [.isSelected] : [])
    }

    /// Whether `Add` can do anything — a name that is already in the vocabulary would be
    /// swallowed silently, with the field left full and nothing said.
    func canAddCustomName() -> Bool {
        let name = customName.trimmingCharacters(in: .whitespaces)
        return RestructurePlanner.isValidTargetName(name) && !vocabulary.contains(name)
    }

    private func addCustomName() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        // The planner's own rule (one folder name, no separators or traversal), checked at the
        // door: without it a typed "Tax/2024" or "../Shared" became a picker target, and the
        // apply's bare path-append would have moved folders outside the family entirely. The
        // derivation refuses such a target too — this guard keeps it out of the vocabulary,
        // where every member's picker would offer it.
        guard RestructurePlanner.isValidTargetName(name), !vocabulary.contains(name) else {
            return
        }
        vocabulary.append(name)
        chosenScheme = nil
        customName = ""
    }

    // MARK: - 2. The mapping editor

    private func mappingSection(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionLabel(isSeededPair
                             ? "Mapping — one row per name in this folder, default keep"
                             : "Mapping — one row per name found across the family, default keep")
                Spacer(minLength: 8)
                Text(Self.mappedCount(rows))
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            // 24 rows on the flagship family: past a dozen the list stops being scannable and
            // the name you are looking for is the thing you cannot find. The filter narrows the
            // VIEW only — `rows` stays canonical and complete, so the derived manifest below is
            // identical with a filter active.
            if rows.count > Self.filterAppearsAbove {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter names", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.system(size: 11))
                        .frame(width: 220)
                        .accessibilityLabel("Filter the mapping by name")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach($rows) { $row in
                        if Self.matches(row.source, filter: filterText) {
                            mappingRow($row, plan: plan)
                        }
                    }
                }
            }
            .frame(maxHeight: 210)
        }
    }

    private func mappingRow(_ row: Binding<RestructureMapping.Row>,
                            plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)
        -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(row.wrappedValue.source)
                    .scaledFont(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                // A quiet marker saying WHY this row has the neighbour it has — without it,
                // adjacency is a reordering the reader cannot account for.
                if Self.hasSimilarNeighbour(row.wrappedValue, in: rows) {
                    Image(systemName: "link")
                        .scaledFont(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Near-identical to the row beside it")
                }
            }
            .frame(width: 220, alignment: .leading)
            Picker("", selection: row.target) {
                Text("Keep").tag(String?.none)
                ForEach(pickerTargets(for: row.wrappedValue), id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .labelsHidden()
            // The visible label is the source name to its left; VoiceOver needs the tie made
            // explicit or this is an unnamed popup in a column of unnamed popups.
            .accessibilityLabel("Target for \(row.wrappedValue.source)")
            .scaledFont(.system(size: 11))
            .frame(width: 180)
            if let margin = margin(for: row.wrappedValue, plan: plan) {
                // The cost of a choice, visible where it is made (§5.4 step 3).
                Text(margin)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// The dropdown's names: the chosen vocabulary, plus whatever this row already points at
    /// (a draft can carry a name the current vocabulary no longer lists).
    private func pickerTargets(for row: RestructureMapping.Row) -> [String] {
        var names = vocabulary
        if let target = row.target, !names.contains(target) { names.append(target) }
        return names
    }

    // MARK: - 2b. Refine with Claude (§5.6)

    @ViewBuilder
    private var refineSection: some View {
        if onRefineMapping != nil {
            VStack(alignment: .leading, spacing: 6) {
                if refineOffered {
                    HStack(spacing: 10) {
                        // The one live control while a refine is in flight: without it, Cancel
                        // (held for the reason on the footer) left the whole sheet dead for the
                        // transport's full 90 s timeout on a hung request.
                        Button {
                            refining ? stopRefine() : runRefine()
                        } label: {
                            Label(refining ? "Stop asking"
                                  : "Ask \(refineModelLabel) about \(rows.count) folder "
                                    + "name\(rows.count == 1 ? "" : "s")",
                                  systemImage: refining ? "stop.circle" : "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(rows.isEmpty)
                        Toggle("Include up to 5 file names per folder", isOn: $includeFileSamples)
                            .toggleStyle(.checkbox)
                            .scaledFont(.system(size: 10.5))
                            .disabled(refining)
                    }
                    // The itemised payload disclosure, at the button rather than behind it —
                    // and the toggle's clause appears only when the toggle is on.
                    Text(Self.payloadDisclosure(includesFileNames: includeFileSamples))
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let onConfigureRefine {
                    Button(action: onConfigureRefine) {
                        Label("Refine names with Claude…", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Proposes consistent names for this family's folders — billed to your "
                          + "own API key, set up in Settings ▸ Intelligence. The mapping stays "
                          + "yours: accepting a proposal edits a row, and the plan re-derives.")
                }
                if let refineFailedText {
                    Text(refineFailedText)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if let proposals {
                    proposalList(proposals)
                }
            }
        }
    }

    @ViewBuilder
    private func proposalList(_ proposals: [MappingRefineProposal]) -> some View {
        // Capped and scrollable like the mapping (210), the operations (150) and the preview
        // (130). Twenty-four proposals of two to three wrapped lines each is the same unbounded
        // growth that once pushed this sheet's footer off a short display.
        ScrollView { proposalRows(proposals) }
            .frame(maxHeight: 170)
    }

    private func proposalRows(_ proposals: [MappingRefineProposal]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(proposals) { proposal in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(proposal.source)
                        .scaledFont(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.proposalLine(proposal))
                            .scaledFont(.system(size: 10.5,
                                                weight: proposal.verdict == .declined
                                                    ? .regular : .medium))
                            .foregroundStyle(proposal.verdict == .declined
                                             ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        Text(proposal.why)
                            .scaledFont(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // §5.6's adjacency rule: a proposal that reverses another — or the
                        // user's own row — is labelled, or a reviewer reads the pair as a bug.
                        if let note = MappingRefineProtocol.reversalNote(for: proposal,
                                                                         among: proposals,
                                                                         rows: rows) {
                            // A warm CAPSULE, not warm text. Amber on 9.5pt body text is the
                            // contrast trap this branch states as a rule twice and follows twice
                            // elsewhere — the radius chip and the crowding tag both carry their
                            // tint as a fill with `.secondary` text, and this is the same shape.
                            Text(note)
                                .scaledFont(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 1)
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Color.orange.opacity(0.16)))
                        }
                    }
                    Spacer(minLength: 4)
                    if let accepted = acceptedTarget(of: proposal),
                       rows.first(where: { $0.source == proposal.source })?.target != accepted {
                        Button("Accept") { accept(proposal) }
                            // Every proposal row says "Accept" — VoiceOver needs each to name
                            // WHICH proposal it lands.
                            .accessibilityLabel(
                                "Accept for \(proposal.source): \(Self.proposalLine(proposal))")
                            .scaledFont(.system(size: 10.5, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(accent)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.well).fill(.quaternary.opacity(0.2)))
    }

    /// What accepting would set the row's target to — nil-in-optional for keep, absent for
    /// declined (nothing to accept).
    private func acceptedTarget(of proposal: MappingRefineProposal) -> String?? {
        switch proposal.verdict {
        case .propose(let target): return .some(target)
        case .keep: return .some(nil)
        case .declined: return nil
        }
    }

    /// **No path to the disk that skips the manifest**: accepting edits the mapping row, the
    /// derivation re-runs, and the review below is the same review it always was.
    private func accept(_ proposal: MappingRefineProposal) {
        guard let target = acceptedTarget(of: proposal),
              let index = rows.firstIndex(where: { $0.source == proposal.source }) else { return }
        rows[index].target = target
        if let newTarget = target, !vocabulary.contains(newTarget) {
            vocabulary.append(newTarget)
        }
    }

    private func runRefine() {
        guard !refining, let onRefineMapping else { return }
        let request = refineRequest()
        refining = true
        refineFailedText = nil
        // A failed second run must not leave the FIRST run's proposals rendered under its own
        // failure sentence — nothing would say which run they belong to.
        proposals = nil
        refineTask = Task { @MainActor in
            let outcome = await onRefineMapping(request)
            // Stopped by hand: `stopRefine` already wrote the honest sentence, and whatever
            // the cancelled transport returned (usually `.unavailable`) must not replace it.
            guard !Task.isCancelled else { return }
            refining = false
            switch outcome {
            case .proposals(let result):
                proposals = result
            case .declined:
                // Their choice, not a failure — "check your key" would be the wrong sentence.
                refineFailedText = "Declined at the estimate — nothing was sent."
            case .unavailable:
                refineFailedText = "The pass didn’t run — the key, the budget caps or the "
                    + "network said no. Settings ▸ Intelligence has the details."
            }
        }
    }

    private func stopRefine() {
        refineTask?.cancel()
        refineTask = nil
        refining = false
        // Honest about the money: cancellation stops the WAIT; a request already on the wire
        // may still complete server-side and bill.
        refineFailedText = "Stopped — nothing was accepted. If the request had already gone "
            + "out, it may still bill."
    }

    private func refineRequest() -> MappingRefineRequest {
        var samples: [String: [String]] = [:]
        if includeFileSamples {
            for row in rows {
                var names: [String] = []
                for member in members where names.count < 5 {
                    let path = (((family as NSString).appendingPathComponent(member))
                        as NSString).appendingPathComponent(row.source)
                    if let files = tree.files(path) {
                        names.append(contentsOf: files.prefix(5 - names.count))
                    }
                }
                if !names.isEmpty { samples[row.source] = names }
            }
        }
        var vocabularies = finding.schemes.map(\.vocabulary)
        if !vocabulary.isEmpty { vocabularies.append(vocabulary) }
        // `family`, NOT `planFamily`: every consumer reads a member as a child of the family,
        // and `planFamily` is already `family/member` on a seeded pair — the prompt then
        // described `Docs/Travel/Travel`, a path that does not exist.
        return MappingRefineRequest(family: family, members: members, rows: rows,
                                    candidateVocabularies: vocabularies,
                                    sampleFileNames: samples)
    }

    /// The disclosure sentence — itemised, with the toggle's clause present exactly when the
    /// payload carries it, and the never-clause always (§5.6).
    static func payloadDisclosure(includesFileNames: Bool) -> String {
        var sent = "Sends this family’s folder paths, member names and candidate names"
        if includesFileNames { sent += ", plus up to 5 file names per folder" }
        return sent + ". File contents are never sent. Billed to your API key."
    }

    /// One proposal's verdict, as its row's first line.
    static func proposalLine(_ proposal: MappingRefineProposal) -> String {
        switch proposal.verdict {
        case .propose(let target): return "→ \(target)"
        case .keep: return "keep"
        case .declined: return "declined — not enough evidence to say"
        }
    }

    // MARK: - 3. Review

    private var derived: Result<RestructureManifest, RestructurePlanner.PlanRefusal> {
        RestructurePlanner.manifest(
            family: family, members: members,
            mapping: RestructureMapping(rows: rows), kind: finding.kind, in: tree,
            profileId: profileId, manifestId: manifestId, createdAt: createdAt,
            // What the landing gets CALLED. For a seeded pair the family is the pair's
            // grandparent — recording that would head the ledger card "Across the tree" for two
            // folders inside one named parent.
            recordedFamily: planFamily)
    }

    @ViewBuilder
    private func reviewSection(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Derived operations")
            switch plan {
            case .success(let manifest):
                Text(RestructureLedger(of: manifest).summary)
                    .scaledFont(.system(size: 11, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Self.operationLines(of: manifest, walkedFamily: family),
                                id: \.self) { line in
                            Text(line)
                                .scaledFont(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                // The operations say what runs; this says what it LEAVES. One member, because
                // the mapping is applied to all of them identically and one worked example is
                // what makes the shape legible — the list above is the exhaustive answer.
                if let exemplar = Self.previewMember(of: manifest, family: family,
                                                    members: members),
                   let preview = RestructurePlanner.preview(member: exemplar, in: manifest,
                                                            tree: tree) {
                    treePreview(exemplar, preview)
                }
            case .failure(let refusal):
                Text(Self.refusalText(refusal))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Which member the before/after is drawn for: the first one the plan actually touches, in
    /// the manifest's own order. A member the plan leaves alone would draw two identical columns
    /// and teach nothing.
    ///
    /// A rule rather than a method, because a render comparison cannot see it: two sheets whose
    /// plans differ also differ in their mapping rows and their operation list, so the images
    /// differ whether or not the columns draw. `if true { return nil }` here passed one.
    static func previewMember(of manifest: RestructureManifest,
                              family: String, members: [String]) -> String? {
        for action in manifest.actions where action.action != .keep {
            guard let path = action.src ?? action.dst else { continue }
            for member in members {
                let full = (family as NSString).appendingPathComponent(member)
                if RestructurePaths.isInside(path, of: full) { return full }
            }
        }
        return nil
    }

    /// Two mono columns — the member as it stands, and as this plan would leave it.
    private func treePreview(_ member: String,
                             _ preview: RestructurePlanner.RestructurePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\((member as NSString).lastPathComponent) — before and after")
                .scaledFont(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            // Capped and scrollable, like the mapping (210) and the operations (150) above it.
            // A 17-child member draws 17 rows a side plus their notes, and the sheet has no
            // outer ScrollView — at the largest text size the footer went off the display and
            // the sheet could only be dismissed with Escape.
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    previewColumn("NOW", rows: preview.before)
                    previewColumn("AFTER", rows: preview.after)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
        }
    }

    private func previewColumn(_ title: String,
                               rows: [RestructurePlanner.RestructurePreview.Row]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .scaledFont(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .scaledFont(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let files = row.files {
                        Text("\(files)")
                            .scaledFont(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                if let note = Self.fateNote(row.fate) {
                    Text(note)
                        .scaledFont(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.18)))
    }

    /// What became of a row, in the after column's own words. nil for a folder the plan never
    /// touched — an annotation on every row is an annotation nobody reads.
    static func fateNote(_ fate: RestructurePlanner.RestructurePreview.Fate) -> String? {
        switch fate {
        case .renamedFrom(let old): return "was \(old)"
        case .mergedFrom(let old, let sources):
            let absorbed = "absorbed \(sources.joined(separator: ", "))"
            return old.map { "was \($0), " + absorbed } ?? absorbed
        case .created: return "created"
        case .kept: return "kept — no slot in the target shape"
        case .unchanged: return nil
        }
    }

    // MARK: - Footer

    private func footer(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        HStack(spacing: 10) {
            switch outcome {
            case .exported(let name):
                Text("Exported as \(name) — nothing has been moved.")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .applied(let summary):
                Text("Applied — \(summary).")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .failed(let sentence):
                Text(sentence)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            Spacer()
            // "Done" only after a LANDING — an exported plan or a refusal both close as
            // "Cancel"-shaped acts (nothing on disk moved). Held while an apply or a paid
            // refine is in flight: a "Cancel" clicked mid-apply reads as *abort*, but the
            // eight-step landing keeps running, and a refusal (or the paid proposals) would
            // land in a torn-down view with no banner to catch it.
            Button(isApplied ? "Done" : "Cancel") { onClose() }
                .scaledFont(.system(size: 11))
                .keyboardShortcut(.cancelAction)
                .disabled(applying || refining)
            // Export keeps ⏎ — the safe act stays the default one; landing a plan is a plain
            // deliberate click, styled as the destructive act it is.
            // Disabled once applied, like Apply itself: an export saves a draft, and a draft
            // saved AFTER the landing would put "Planned, not applied" on a card about
            // operations that just ran.
            Button("Export plan…") { exportPlan(plan) }
                .scaledFont(.system(size: 11, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled((try? plan.get()) == nil || applying || isApplied)
            if let onApply {
                Button(applyTitle(plan)) { apply(plan, onApply) }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .disabled((try? plan.get()) == nil || applying || isApplied)
                    .help("Runs the reviewed operations now: renames and merges on disk, one "
                          + "grouped ⌘Z, the inverse in the ledger, and the survey re-derived.")
            }
        }
    }

    /// §5.5's eight steps as they run. **The point is the order**: the inverse reaches disk
    /// before anything moves, and the verify is a separate pass afterwards — the trust the
    /// design paid for, previously invisible behind a button reading "Applying…".
    private func progressChecklist(_ progress: RestructureApplyProgress) -> some View {
        RestructureApplyChecklist(progress: progress, accent: accent)
    }
}

/// §5.5's eight steps as they run, for whichever sheet is landing. Extracted rather than left
/// private to the plan sheet: a pair merge runs the same `applyPlan`, through the same inverse-
/// first order, and showed none of it.
struct RestructureApplyChecklist: View {
    let progress: RestructureApplyProgress
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RestructureApplyProgress.Stage.allCases, id: \.rawValue) { stage in
                HStack(spacing: 6) {
                    Image(systemName: RestructurePlanSheet.stageSymbol(stage, current: progress.stage))
                        .scaledFont(.system(size: 9))
                        .foregroundStyle(stage < progress.stage ? AnyShapeStyle(accent)
                                                                : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(stage == progress.stage ? progress.line()
                                                 : RestructureApplyProgress.label(stage))
                        .scaledFont(.system(size: 10.5,
                                            weight: stage == progress.stage ? .semibold
                                                                            : .regular))
                        .foregroundStyle(stage <= progress.stage ? AnyShapeStyle(.secondary)
                                                                 : AnyShapeStyle(.tertiary))
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Applying — \(progress.line())")
    }
}

extension RestructurePlanSheet {

    /// Done, doing, still to come. A landing only moves forward, so a stage behind the current
    /// one is finished and one ahead has not started.
    static func stageSymbol(_ stage: RestructureApplyProgress.Stage,
                            current: RestructureApplyProgress.Stage) -> String {
        if stage < current { return "checkmark.circle.fill" }
        if stage == current { return "circle.dotted" }
        return "circle"
    }

    private var isApplied: Bool {
        if case .applied = outcome { return true }
        return false
    }

    private func applyTitle(_ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)
        -> String {
        // `operationCount`, not `actions.count`: keeps are the signature block, and counting
        // them read "Apply 14 operations" in red over one rename plus 13 keeps.
        let count = (try? plan.get())?.operationCount ?? 0
        return applying ? "Applying…" : "Apply \(count) operation\(count == 1 ? "" : "s")"
    }

    private func apply(_ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
                       _ run: @escaping (RestructureManifest) async -> ApplyResult) {
        // The button's .disabled only holds if SwiftUI re-rendered between a double-click's two
        // clicks; this guard is what actually stops a second eight-step apply racing the first.
        guard !applying, let manifest = try? plan.get() else { return }
        applying = true
        Task { @MainActor in
            let result = await run(manifest)
            applying = false
            switch result {
            case .applied(let summary): outcome = .applied(summary)
            case .refused(let refusal): outcome = .failed(refusal)
            }
        }
    }

    private func exportPlan(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) {
        guard let manifest = try? plan.get() else { return }
        switch onExport(manifest, vocabulary) {
        case .saved(let filename): outcome = .exported(filename)
        case .failed(let failure): outcome = .failed(failure)
        }
    }

    // MARK: - Small pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// "merges into `Forms` in 3 members" — how many members this row's choice makes a merge in,
    /// read off the live derivation so the margin can never disagree with the review below.
    private func margin(for row: RestructureMapping.Row,
                        plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)
        -> String? {
        guard let target = row.target, target != row.source,
              case .success(let manifest) = plan else { return nil }
        let memberCount = Set(manifest.actions.compactMap { action -> String? in
            guard action.action == .moveFile || action.action == .moveDir,
                  let src = action.src else { return nil }
            let prefix = family.isEmpty ? "" : family + "/"
            guard src.hasPrefix(prefix) else { return nil }
            let rest = src.dropFirst(prefix.count)
            let parts = rest.split(separator: "/", maxSplits: 2)
            guard parts.count >= 2, String(parts[1]) == row.source else { return nil }
            return String(parts[0])
        }).count
        guard memberCount > 0 else { return nil }
        return "merges into \(target) in \(memberCount) member\(memberCount == 1 ? "" : "s")"
    }

    // MARK: - Static rules (tested without the view)

    /// The label a scheme wears in the chooser — what it IS, never a recommendation: *the largest
    /// group* for the widest membership, *the most recent* derived from the members' year tokens,
    /// never from scheme order (§5.4 step 1's audit note).
    static func schemeLabel(index: Int, in finding: StructureFinding) -> String? {
        // Labels exist to tell choices apart; a lone scheme is the only choice, and "the most
        // recent" of one would be a recommendation wearing a description's words.
        guard finding.schemes.count > 1 else { return nil }
        var parts: [String] = []
        if index == 0 { parts.append("the largest group") }
        if index == mostRecentSchemeIndex(of: finding) { parts.append("the most recent") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The vouched scheme whose members reach the newest year — nil when no member of any scheme
    /// carries a year token at all.
    static func mostRecentSchemeIndex(of finding: StructureFinding) -> Int? {
        let newest = finding.schemes.enumerated().compactMap { index, scheme -> (Int, Int)? in
            let years = scheme.members.compactMap(maxYear(in:))
            guard let top = years.max() else { return nil }
            return (index, top)
        }
        return newest.max { $0.1 < $1.1 }?.0
    }

    /// True when the genuinely newest members are drift or shapeless — then there is no current
    /// shape, and saying so is the true and useful answer (§5.4 step 1).
    static func newestMembersAreDrift(_ finding: StructureFinding) -> Bool {
        let driftYears = (finding.drift + finding.shapeless).compactMap(maxYear(in:))
        let schemeYears = finding.schemes.flatMap(\.members).compactMap(maxYear(in:))
        guard let newestDrift = driftYears.max() else { return false }
        guard let newestScheme = schemeYears.max() else { return true }
        return newestDrift > newestScheme
    }

    /// The largest plausible year token in a member's name — `2016-2019` reads 2019,
    /// `IRS Docs - 2023` reads 2023, `CA State` reads nothing.
    static func maxYear(in name: String) -> Int? {
        var years: [Int] = []
        var digits = ""
        for character in name + " " {
            if character.isNumber {
                digits.append(character)
            } else {
                if digits.count == 4, let year = Int(digits), (1900...2200).contains(year) {
                    years.append(year)
                }
                digits = ""
            }
        }
        return years.max()
    }

    /// The review list, grouped the way §5.4 words it: renames one line each, a merge one line
    /// per source-into-target with its file and folder counts, keeps by name — every line
    /// prefixed by the member it happens in.
    static func operationLines(of manifest: RestructureManifest,
                               walkedFamily: String? = nil) -> [String] {
        // The family the paths were WALKED from, which since `recordedFamily` is not always the
        // one the manifest records: a seeded pair records the member's own path, so stripping
        // that prefix yielded the child name where the member's was wanted.
        let family = walkedFamily ?? manifest.family
        let familyPrefix = family.isEmpty ? "" : family + "/"
        func member(of path: String?) -> String {
            guard let path, path.hasPrefix(familyPrefix) else { return "" }
            return String(path.dropFirst(familyPrefix.count).split(separator: "/").first ?? "")
        }
        func name(_ path: String?) -> String {
            ((path ?? "") as NSString).lastPathComponent
        }
        // A merge is many primitive moves; the sheet groups them per (source dir, target dir),
        // and every line keeps the position its first action held, so the list reads in the
        // order the manifest runs.
        var ordered: [(order: Int, text: String)] = []
        var mergeCounts: [String: (member: String, source: String, target: String,
                                   files: Int, folders: Int, order: Int)] = [:]
        for (index, action) in manifest.actions.enumerated() {
            switch action.action {
            case .renameDir:
                let carried = action.filesCarried ?? 0
                ordered.append((index, "\(member(of: action.src)) · rename \(name(action.src)) → "
                    + "\(name(action.dst)) (\(carried) file\(carried == 1 ? "" : "s"))"))
            case .moveFile, .moveDir:
                let sourceDir = ((action.src ?? "") as NSString).deletingLastPathComponent
                let targetDir = ((action.dst ?? "") as NSString).deletingLastPathComponent
                let key = sourceDir + "→" + targetDir
                var entry = mergeCounts[key] ?? (member(of: action.src), name(sourceDir),
                                                 name(targetDir), 0, 0, index)
                if action.action == .moveFile { entry.files += 1 } else { entry.folders += 1 }
                mergeCounts[key] = entry
            case .keep:
                ordered.append((index, "\(member(of: action.src)) · keep \(name(action.src))"))
            case .createDir:
                ordered.append((index, "\(member(of: action.dst)) · create \(name(action.dst))/"))
            case .removeEmptyDir:
                ordered.append((index,
                                "\(member(of: action.src)) · remove empty \(name(action.src))/"))
            }
        }
        for entry in mergeCounts.values {
            var counts = ["\(entry.files) file\(entry.files == 1 ? "" : "s")"]
            if entry.folders > 0 {
                counts.append("\(entry.folders) folder\(entry.folders == 1 ? "" : "s")")
            }
            ordered.append((entry.order, "\(entry.member) · merge \(entry.source) into "
                + "\(entry.target) (\(counts.joined(separator: ", ")))"))
        }
        return ordered.sorted { $0.order < $1.order }.map(\.text)
    }

    static func refusalText(_ refusal: RestructurePlanner.PlanRefusal) -> String {
        switch refusal {
        case .nothingMapped:
            return "Every row is keep — nothing would change. Map at least one name to see the "
                + "operations it derives."
        case .unknownFiles(let source):
            return "A merge needs the files inside \(source), and they could not be listed. "
                + "Check the folder is reachable and try again."
        case .unresolvableOrder(let member):
            return "The mapping loops through a merge in \(member) in a way that cannot be "
                + "ordered safely. Simplify the circular renames and try again."
        case .conflictingTargets(let first, let second):
            return "\(first) and \(second) differ only by capitalisation, and this volume "
                + "cannot hold both side by side. Pick one spelling."
        case .targetTakenByCase(let target, let standing, let member):
            return "\(member) already holds \(standing), which differs from \(target) only by "
                + "capitalisation — the volume cannot hold both. Map \(standing) to \(target) "
                + "to step its case up, reuse its spelling — or, if this plan moves "
                + "\(standing) elsewhere, land that change on its own first."
        case .duplicateMappingRows(let source):
            return "The mapping lists \(source) on two rows, and the rows may disagree — one "
                + "row per name. Remove the duplicate and try again."
        case .invalidTargetName(let target):
            return "“\(target)” is not one folder name — a target cannot carry a path "
                + "separator or dot traversal. Rename it to a single name and try again."
        case .targetTakenByFile(let target, let member):
            return "\(member) holds a FILE named \(target), and a folder cannot take a "
                + "standing file's name. Move or rename the file first."
        }
    }

    /// The shared stamp, for callers composing their own manifest ids (the removal step).
    static func nowStamp() -> String { stamp(Date()) }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}
