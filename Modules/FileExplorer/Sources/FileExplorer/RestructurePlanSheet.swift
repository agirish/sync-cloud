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
    /// Every member of the family — scheme members, drift and shapeless alike: the mapping is
    /// applied to all of them, and drift is the part that most needs housing.
    let members: [String]
    /// The tree as it stands now — disk-backed in the app, dictionary-backed in tests.
    let tree: RestructureTreeView
    let profileId: String
    let accent: Color
    /// A saved draft's rows, so *Review N operations* reopens the plan as it was left.
    var initialRows: [RestructureMapping.Row]?
    /// Writes the export file and saves the draft; returns a failure sentence, or nil on success.
    let onExport: (RestructureManifest) -> String?
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
    @State private var outcome: Outcome?
    @State private var createdAt = ""
    @State private var manifestId = ""

    private enum Outcome: Equatable {
        case exported(String)
        case failed(String)
    }

    var body: some View {
        // Derived ONCE per render and handed down. The margin renders per row, and a version
        // that re-derived inside it ran the whole planner — disk listings included — once per
        // row per render; 24 rows made that a couple of hundred directory reads per keystroke.
        let plan = derived
        return VStack(alignment: .leading, spacing: 14) {
            header
            shapeSection
            mappingSection(plan)
            reviewSection(plan)
            footer(plan)
        }
        .padding(18)
        .frame(width: 620)
        .frame(minHeight: 460)
        .onAppear(perform: seed)
        .onChange(of: rows) {
            // An edit after an export describes a NEW plan; the old outcome sentence would be
            // claiming this one was exported.
            outcome = nil
        }
    }

    // MARK: - Seeding

    private func seed() {
        guard rows.isEmpty else { return }
        let sources = RestructurePlanner.distinctSources(family: finding.family,
                                                         members: members, in: tree)
        allSources = sources
        parallelFamilies = RestructurePlanner.parallelFamilies(of: finding.family, in: tree)
        if let initialRows {
            // The draft's rows, reconciled against the sources as they stand now: a source that
            // appeared since the draft gets a fresh keep row; one that vanished drops off.
            let saved = Dictionary(uniqueKeysWithValues: initialRows.map { ($0.source, $0) })
            rows = sources.map { saved[$0] ?? RestructureMapping.Row(source: $0) }
            vocabulary = orderedTargets(of: rows)
        } else {
            // Default keep on every row — the editor never guesses a mapping (§5.4 step 3).
            rows = sources.map { RestructureMapping.Row(source: $0) }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(finding.family)
                .scaledFont(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Text("One mapping, edited once, applied to every member — the operations below are "
                 + "derived from it, never typed.")
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

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Target shape")
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
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func schemeChoice(index: Int, scheme: StructureFinding.Scheme) -> some View {
        Button {
            chosenScheme = index
            // The detector lowercases its vocabulary for comparison; target names take the
            // disk-cased spelling the family actually uses — the scaffold's own casing rule.
            vocabulary = scheme.vocabulary.map { word in
                allSources.first { $0.lowercased() == word } ?? word.localizedCapitalized
            }
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
    }

    private func addCustomName() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !vocabulary.contains(name) else { return }
        vocabulary.append(name)
        chosenScheme = nil
        customName = ""
    }

    // MARK: - 2. The mapping editor

    private func mappingSection(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Mapping — one row per name found across the family, default keep")
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach($rows) { $row in
                        mappingRow($row, plan: plan)
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
            Text(row.wrappedValue.source)
                .scaledFont(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
            Picker("", selection: row.target) {
                Text("Keep").tag(String?.none)
                ForEach(pickerTargets(for: row.wrappedValue), id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .labelsHidden()
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

    // MARK: - 3. Review

    private var derived: Result<RestructureManifest, RestructurePlanner.PlanRefusal> {
        RestructurePlanner.manifest(
            family: finding.family, members: members,
            mapping: RestructureMapping(rows: rows), kind: finding.kind, in: tree,
            profileId: profileId, manifestId: manifestId, createdAt: createdAt)
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
                        ForEach(Self.operationLines(of: manifest), id: \.self) { line in
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
            case .failure(let refusal):
                Text(Self.refusalText(refusal))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
            case .failed(let sentence):
                Text(sentence)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            Spacer()
            Button(outcome == nil ? "Cancel" : "Done") { onClose() }
                .scaledFont(.system(size: 11))
            Button("Export plan…") { exportPlan(plan) }
                .scaledFont(.system(size: 11, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled((try? plan.get()) == nil)
        }
    }

    private func exportPlan(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) {
        guard let manifest = try? plan.get() else { return }
        if let failure = onExport(manifest) {
            outcome = .failed(failure)
        } else {
            outcome = .exported("restructure-\(manifest.createdAt.prefix(while: { $0 != "T" }))-"
                + manifest.family.replacingOccurrences(of: "/", with: "-") + ".json")
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
            let prefix = finding.family + "/"
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
    static func operationLines(of manifest: RestructureManifest) -> [String] {
        let familyPrefix = manifest.family + "/"
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
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}
