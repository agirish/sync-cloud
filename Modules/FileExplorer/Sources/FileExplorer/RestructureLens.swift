import SwiftUI
import Design
import Sync

/// Organize ▸ Restructure: families of sibling folders that were shaped differently at different
/// times.
///
/// **Report-only, deliberately.** A finding says *these thirteen folders use four different
/// internal shapes*; it does not offer to fix them. The fix is a manifest of typed operations —
/// create, rename, move — over years of documents, and that surface has six invariants of its own
/// to satisfy before it can be safe to aim at a real tree (ROADMAP 20). Naming the disagreement is
/// the half that is useful on its own and cannot do any harm.
///
/// The three states are distinct on purpose, and none of them borrows another's words: **no
/// profile** means the detectors have nothing to read, **no findings** means they ran and the tree
/// agrees with itself, and a list means it does not.
struct RestructureLens: View {
    let findings: [StructureFinding]
    let hasProfile: Bool
    let folderCount: Int
    let accent: Color
    let onReveal: (String) -> Void

    var body: some View {
        if !hasProfile {
            noProfileState
        } else if findings.isEmpty {
            cleanState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(findings) { finding in
                        findingCard(finding)
                    }
                }
                .padding(12)
            }
        }
    }

    private func findingCard(_ finding: StructureFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.family)
                        .scaledFont(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("\(finding.memberCount) folders, \(finding.schemes.count) internal shapes")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Reveal") { onReveal(finding.family) }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .chromeHover()
            }
            // The schemes are shown rather than asserted: the eras are visible, and so is the odd
            // year out. A verdict that only said "these disagree" would be asking to be trusted.
            ForEach(Array(finding.schemes.enumerated()), id: \.offset) { _, scheme in
                schemeRow(scheme)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
    }

    private func schemeRow(_ scheme: StructureFinding.Scheme) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(scheme.members.joined(separator: ", "))
                .scaledFont(.system(size: 11, weight: .medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(2)
            // The vocabulary these siblings AGREE on — the intersection. A union would advertise
            // one member's stray extra as part of the convention.
            Text(scheme.vocabulary.isEmpty
                 ? "no shared subfolders"
                 : scheme.vocabulary.joined(separator: " · "))
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.30)))
    }

    private var cleanState: some View {
        EmptyStateView(icon: "checkmark.seal",
                       title: "The tree agrees with itself",
                       message: "Checked \(folderCount) folders. No family of sibling folders is "
                              + "using more than one internal shape.")
    }

    private var noProfileState: some View {
        EmptyStateView(icon: "square.stack.3d.up.slash",
                       title: "No folder profile yet",
                       message: "Restructure reads the survey of your tree rather than the disk, so "
                              + "it needs that survey first. Settings ▸ Organize sets it up.")
    }
}
