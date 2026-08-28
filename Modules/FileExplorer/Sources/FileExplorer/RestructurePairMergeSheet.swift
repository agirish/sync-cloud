import Design
import SwiftUI
import Sync

/// The confirm surface for a **cross-parent** pair merge — an inbox folder mirroring its real
/// destination, a loose folder beside the container it belongs in, a child echoing its parent
/// (ROADMAP_V5 §5.2; the audit's G2).
///
/// There is no mapping to edit here and no shape to choose: the pair is two paths, and the
/// operations follow from them. So this sheet is the review section alone — the derived
/// operations, the ledger's own sentence about them, and the two buttons that write. Everything
/// it shows comes from ``RestructurePlanner/pairMergeManifest(source:destination:kind:in:profileId:manifestId:createdAt:note:)``,
/// so what is listed IS what lands; there is no second derivation to drift.
struct RestructurePairMergeSheet: View {
    let source: String
    let destination: String
    let kind: FindingKind
    /// The tree as it stands now — disk-backed in the app, dictionary-backed in tests.
    let tree: RestructureTreeView
    let profileId: String
    let accent: Color
    /// The sentence the finding's card makes about this pair, carried into the sheet so the
    /// review opens on the claim it was opened from.
    let rationale: String
    let onExport: (RestructureManifest) -> RestructurePlanSheet.ExportResult
    var onApply: ((RestructureManifest) async -> RestructurePlanSheet.ApplyResult)?
    let onClose: () -> Void

    @State private var createdAt = ""
    @State private var manifestId = ""
    @State private var outcome: Outcome?
    @State private var applying = false
    @State private var landed = false

    private enum Outcome: Equatable {
        case exported(String)
        case applied(String)
        case failed(String)
    }

    var body: some View {
        // Derived once per render and handed down, the plan sheet's rule: the header, the list
        // and the footer all read the same value rather than each re-running the planner.
        let plan = derived
        return VStack(alignment: .leading, spacing: 12) {
            header
            operationsSection(plan)
            footer(plan)
        }
        .padding(18)
        .frame(width: 560)
        .frame(minHeight: 380)
        .onAppear(perform: seed)
    }

    private func seed() {
        guard createdAt.isEmpty else { return }
        let stamp = RestructurePlanSheet.nowStamp()
        createdAt = stamp
        manifestId = "plan-\(kind.rawValue)-\(stamp)"
    }

    private var derived: Result<RestructureManifest, RestructurePlanner.PlanRefusal> {
        RestructurePlanner.pairMergeManifest(
            source: source, destination: destination, kind: kind, in: tree,
            profileId: profileId, manifestId: manifestId, createdAt: createdAt,
            note: Self.note(source: source, destination: destination))
    }

    /// The manifest's own written justification — read in a text editor, away from this sheet.
    static func note(source: String, destination: String) -> String {
        "Pair merge: \(source) into \(destination). Derived from the pair alone — there is no "
        + "mapping to edit, and the emptied folder is left standing for the removal step."
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.title(source: source, destination: destination))
                .scaledFont(.system(size: 13, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(source)
                    .scaledFont(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "arrow.right")
                    .scaledFont(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(destination)
                    .scaledFont(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(rationale)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func title(source: String, destination: String) -> String {
        "Merge \((source as NSString).lastPathComponent) into "
        + "\((destination as NSString).lastPathComponent)"
    }

    // MARK: - The operations

    @ViewBuilder
    private func operationsSection(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch plan {
            case .success(let manifest):
                Text(RestructureLedger(of: manifest).summary)
                    .scaledFont(.system(size: 11, weight: .medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(manifest.actions.enumerated()), id: \.offset) { _, action in
                            operationRow(action)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            case .failure(let refusal):
                // A refusal is a sentence, never an empty list that reads as "nothing to do".
                Text(Self.refusalText(refusal, source: source))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func operationRow(_ action: RestructureManifest.Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.verb(action.action))
                .scaledFont(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(action.src ?? action.dst ?? "—")
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            if let dst = action.dst, action.src != nil {
                Image(systemName: "arrow.right")
                    .scaledFont(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(dst)
                    .scaledFont(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if action.collisionExpected == true {
                Text("both kept")
                    .scaledFont(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 8)
    }

    /// The operation's verb in the words the card and the ledger use — not the schema's raw
    /// value, which is a wire format rather than a sentence.
    static func verb(_ kind: RestructureManifest.ActionKind) -> String {
        switch kind {
        case .createDir: return "create"
        case .renameDir: return "rename"
        case .moveDir: return "move folder"
        case .moveFile: return "move file"
        case .keep: return "keep"
        case .removeEmptyDir: return "remove"
        }
    }

    /// Why no plan could be derived, in the sheet's own words.
    static func refusalText(_ refusal: RestructurePlanner.PlanRefusal, source: String) -> String {
        switch refusal {
        case .nothingMapped:
            return "There is nothing to move — the two paths already resolve to one folder."
        case .unknownFiles(let path):
            return "The files inside \(path) could not be listed, and a merge that cannot name "
                + "what it moves is a guess. Nothing was derived."
        case .unresolvableOrder:
            return "\(source) would have to move inside itself. Nothing was derived."
        case .duplicateMappingRows, .conflictingTargets, .targetTakenByCase:
            // Reachable only through the mapping editor, which this sheet does not have. Named
            // rather than defaulted so a new refusal has to be worded before it can appear.
            return "This pair cannot be planned automatically."
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        HStack(spacing: 10) {
            if let outcome {
                Text(Self.outcomeText(outcome))
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(landed ? "Done" : "Cancel") { onClose() }
                .scaledFont(.system(size: 11))
                .keyboardShortcut(.cancelAction)
                .disabled(applying)
            if case .success(let manifest) = plan {
                Button("Export plan…") { export(manifest) }
                    .scaledFont(.system(size: 11))
                    .disabled(applying || landed)
                if let onApply {
                    Button(applying ? "Applying…" : "Apply") { apply(manifest, run: onApply) }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .disabled(applying || landed)
                }
            }
        }
    }

    private static func outcomeText(_ outcome: Outcome) -> String {
        switch outcome {
        case .exported(let name): return "Exported as \(name) — nothing has moved."
        case .applied(let summary): return summary
        case .failed(let sentence): return sentence
        }
    }

    private func export(_ manifest: RestructureManifest) {
        switch onExport(manifest) {
        case .saved(let filename): outcome = .exported(filename)
        case .failed(let sentence): outcome = .failed(sentence)
        }
    }

    private func apply(_ manifest: RestructureManifest,
                       run: @escaping (RestructureManifest) async
                           -> RestructurePlanSheet.ApplyResult) {
        guard !applying, !landed else { return }
        applying = true
        outcome = nil
        Task { @MainActor in
            let result = await run(manifest)
            applying = false
            switch result {
            case .applied(let summary):
                landed = true
                outcome = .applied(summary)
            case .refused(let refusal):
                // A refusal here is transient — a scan running, the store mid-write — so the
                // button stays armed, exactly as the removal sheet's does.
                outcome = .failed(refusal)
            }
        }
    }
}
