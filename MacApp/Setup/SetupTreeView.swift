import Design
import SwiftUI
import Sync

/// The learned tree, with SyncCloud's reading of each folder beside it.
///
/// **A real outline, not a printed summary.** The point of the Structure screen is that the user
/// can check the reading, and checking means going to the folder they are unsure about — so rows
/// open and close, the keyboard moves through them the way Finder's does, and the box is a fixed
/// height so the switch below it never moves.
struct SetupTreeView: View {
    let profile: FolderProfile
    /// The sibling map and shape findings for `profile`, derived once by the model — see
    /// ``FolderProfileReadings``.
    let readings: FolderProfileReadings
    let rootName: String
    let rootSubtitle: String
    /// The loose files' proposed homes. Empty in the folders view; in the loose view each route
    /// hangs under the folder it would go to.
    var routes: [SetupLooseFileRouting.LooseFileRoute] = []
    let hue: LiquidGlassHue

    @State private var open: Set<String> = []
    @State private var didSeedOpenPath = false

    private var children: [String: [String]] { readings.children }
    private var shapes: [String: StructureFinding] { readings.shapes }

    /// In the loose view, the folders a route names — and every ancestor of them, so a route is
    /// reachable without hunting.
    private var routedPaths: [String: [SetupLooseFileRouting.LooseFileRoute]] {
        Dictionary(grouping: routes.filter { $0.isReady && $0.home != nil },
                   by: { $0.home ?? "" })
    }

    /// One line of the outline, already positioned.
    ///
    /// **Flattened rather than drawn recursively.** A SwiftUI view that calls itself cannot have
    /// its opaque return type inferred — the type would be defined in terms of itself — and the
    /// idiomatic escape is to compute the visible rows first. It also makes the list `LazyVStack`
    /// can actually be lazy about.
    struct Row: Identifiable {
        enum Kind: Equatable {
            case folder(hasChildren: Bool, isOpen: Bool)
            case route(SetupLooseFileRouting.LooseFileRoute)
        }
        let path: String
        let depth: Int
        let kind: Kind
        var id: String {
            if case .route(let route) = kind { return path + "\u{0000}" + route.fileName }
            return path
        }
    }

    /// The rows as they stand, in draw order.
    private var visibleRows: [Row] {
        let children = self.children
        let routed = routedPaths
        var out: [Row] = []
        func walk(_ parent: String, depth: Int) {
            for path in children[parent] ?? [] {
                let hasChildren = !(children[path] ?? []).isEmpty
                let isOpen = open.contains(path)
                out.append(Row(path: path, depth: depth,
                               kind: .folder(hasChildren: hasChildren, isOpen: isOpen)))
                for route in routed[path] ?? [] {
                    out.append(Row(path: path, depth: depth + 1, kind: .route(route)))
                }
                if isOpen, hasChildren { walk(path, depth: depth + 1) }
            }
        }
        walk(FolderSurveyBuilder.rootEntryPath, depth: 1)
        return out
    }

    /// The share of the box's height the closing fade occupies. A fraction rather than a point
    /// value so it stays the same gesture when the box scales with the text.
    static let fadeFraction: CGFloat = 0.07

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                rootRow
                ForEach(visibleRows) { line in
                    switch line.kind {
                    case .folder(let hasChildren, let isOpen):
                        row(line.path, depth: line.depth, hasChildren: hasChildren, isOpen: isOpen)
                    case .route(let route):
                        routeRow(route, depth: line.depth)
                    }
                }
                let unplaced = routes.filter { !$0.isReady }
                if !unplaced.isEmpty {
                    Text("\(unplaced.count) more need your pick — Organize ▸ To File asks about each")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        .padding(.leading, 8)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // **A fade at the foot, because the box is a fixed height and the tree is not.** Its last
        // visible row is cut through the middle of its own glyphs — a hard horizontal slice across
        // a word, which reads as a drawing bug rather than as "there is more of this below".
        //
        // **It has to fade the ROWS, and the first version faded the ground.** That was a wash
        // overlaid at `Color.secondary.opacity(0.05)` — the same value as the box's own fill, so it
        // was invisible on the background and did nothing at all to the glyphs it was drawn over.
        // At 135% the box's 281pt no longer landed on a row boundary and the tree ended in a row
        // sliced through the middle: exactly the defect the fade was added for, with the fade in
        // place. A mask removes the ink, which is the only thing that reads as a continuation.
        .mask(
            LinearGradient(
                stops: [.init(color: .black, location: 0),
                        .init(color: .black, location: 1 - Self.fadeFraction),
                        .init(color: .black.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom))
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Color.secondary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .onAppear(perform: seedOpenPath)
    }

    // MARK: - Rows

    private var rootRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").scaledFont(.caption).foregroundStyle(.tint)
            Text(rootName).scaledFont(.callout.weight(.semibold))
            Text(rootSubtitle).scaledFont(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func row(_ path: String, depth: Int, hasChildren: Bool, isOpen: Bool) -> some View {
        let entry = profile.folders[path]
        let name = (path as NSString).lastPathComponent
        let reading = FolderReading.reading(for: path, in: profile, children: children, shapes: shapes)
        return Button {
            toggle(path)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .opacity(hasChildren ? 1 : 0)
                    .frame(width: 10)
                Text(name).scaledFont(.caption.weight(.medium)).lineLimit(1)
                Text(reading)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(count(entry, hasChildren: hasChildren))
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.row))
        .disabled(!hasChildren)
        // One row, one sentence: the name and what SyncCloud made of it, which is the whole thing
        // being checked here.
        .accessibilityLabel("\(name), \(reading)")
    }

    /// One loose file, under the folder it would go to.
    private func routeRow(_ route: SetupLooseFileRouting.LooseFileRoute, depth: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .scaledFont(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(route.fileName).scaledFont(.caption2).lineLimit(1).truncationMode(.middle)
            Text("would go here").scaledFont(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            Text(Self.tierWord(route.confidence))
                .scaledFont(.caption2.weight(.medium))
                .foregroundStyle(hue.accentColor)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(route.fileName) would go here, \(Self.tierWord(route.confidence)) confidence")
    }

    /// To File's own words for the tiers, so the two screens agree about what a placement is worth.
    static func tierWord(_ confidence: FilingConfidence) -> String {
        switch confidence {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Needs your pick"
        }
    }

    /// What the number on the right of a row counts — folders inside, or files where files go.
    private func count(_ entry: FolderProfileEntry?, hasChildren: Bool) -> String {
        guard let entry else { return "" }
        if hasChildren { return "\(entry.subfolderCount)" }
        return entry.fileCount == 0 ? "" : "\(entry.fileCount) files"
    }

    private func toggle(_ path: String) {
        if open.contains(path) { open.remove(path) } else { open.insert(path) }
    }

    /// Opens along one deep path, so the depth the walk learned is visible and the rest stays
    /// folded.
    ///
    /// **Deepest rather than first**: a tree opened along its first branch shows whatever sorts
    /// earliest, which on a real disk is as likely to be `Archive` as anything worth looking at.
    private func seedOpenPath() {
        guard !didSeedOpenPath else { return }
        didSeedOpenPath = true
        var deepest = ""
        var best = -1
        for path in profile.folders.keys where path != FolderSurveyBuilder.rootEntryPath {
            let depth = path.split(separator: "/").count
            if depth > best || (depth == best && path < deepest) {
                best = depth
                deepest = path
            }
        }
        var ancestors: Set<String> = []
        var walk = (deepest as NSString).deletingLastPathComponent
        while !walk.isEmpty {
            ancestors.insert(walk)
            walk = (walk as NSString).deletingLastPathComponent
        }
        open = ancestors
    }
}
