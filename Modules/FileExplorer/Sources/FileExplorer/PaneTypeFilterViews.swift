import Design
import SwiftUI
import Sync

/// Everything the pane bar's Filter button needs, handed over by the host as one value (RD70).
///
/// `nil` on the header is a header with no Filter button — what every caller outside the app passes,
/// and what keeps the bar, the ladder and the snapshots exactly as they were.
public struct PaneTypeFilterControl {
    /// This pane's filter. `nil` inside is "show everything".
    public var filter: Binding<PaneTypeFilter?>
    /// The census the type list is built from — the pass's facts while a filter is on, the host's
    /// own count of the published tree while none is. `nil` until the first count lands.
    public var facts: PaneTypeFilterFacts?
    /// The folder the counts cover, for "46 files in Downloads and its folders".
    public var folderName: String
    /// The pane is still walking, so the counts can still grow.
    public var isListing: Bool
    /// Compare only: copies this pane's filter to the other pane (FI).
    public var onUseOnBothPanes: (() -> Void)?

    public init(filter: Binding<PaneTypeFilter?>, facts: PaneTypeFilterFacts?, folderName: String,
                isListing: Bool = false, onUseOnBothPanes: (() -> Void)? = nil) {
        self.filter = filter
        self.facts = facts
        self.folderName = folderName
        self.isListing = isListing
        self.onUseOnBothPanes = onUseOnBothPanes
    }

    public var isOn: Bool { filter.wrappedValue != nil }

    /// The button's tooltip, which says the state (TE281).
    public var help: String {
        guard let active = filter.wrappedValue else { return "Filter by Type" }
        return "Showing \(active.showingPhrase). Click to change."
    }

    /// The button's VoiceOver value.
    public var accessibilityValue: String { filter.wrappedValue?.summary ?? "Off" }
}

/// The type list a pane's Filter button opens (TE267–TE270, TE278).
public struct PaneTypeFilterPopover: View {
    let control: PaneTypeFilterControl
    @State private var expanded: Set<FileTypeFamily> = []
    @State private var seeded = false

    public init(control: PaneTypeFilterControl) {
        self.control = control
    }

    private var filter: PaneTypeFilter? { control.filter.wrappedValue }
    private var census: [String: Int] { control.facts?.census ?? [:] }

    /// Kinds to list: every kind present, plus any kind holding a ticked extension this folder lacks.
    var families: [FileTypeFamily] {
        let present = Set(PaneTypeFilter.presentFamilies(in: census))
        let absent = Set((filter?.extensions ?? []).filter { census[$0] == nil }.map(FileTypeFamily.of(extension:)))
        return FileTypeFamily.allCases.filter { present.contains($0) || absent.contains($0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if families.isEmpty {
                Text(control.isListing ? "Still listing this folder…" : "No files in \(control.folderName).")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(families, id: \.self) { family in familyRows(family) }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
            }
            Divider()
            footer
        }
        .scaledFont(.system(size: 12))
        .frame(width: 300)
        .onAppear {
            // Open the kinds that are partly ticked, so the state the checkbox's dash stands for is
            // on screen; everything else starts folded.
            guard !seeded else { return }
            seeded = true
            expanded = Set(families.filter { PaneTypeFilter.tick(of: $0, in: filter, census: census) == .mixed })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Show only").fontWeight(.semibold)
                Spacer()
                Button("All") { control.filter.wrappedValue = nil }
                    .disabled(filter == nil)
                Button("None") { control.filter.wrappedValue = PaneTypeFilter() }
                    .disabled(filter?.isEmpty == true)
            }
            .controlSize(.small)
            Text(scopeLine)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    var scopeLine: String {
        let files = control.facts?.fileCount ?? 0
        return "\(files.formatted()) \(files == 1 ? "file" : "files") in \(control.folderName) and its folders"
    }

    @ViewBuilder
    private func familyRows(_ family: FileTypeFamily) -> some View {
        let present = PaneTypeFilter.presentExtensions(of: family, in: census)
        let absent = PaneTypeFilter.absentTickedExtensions(of: family, in: filter, census: census)
        let all = present + absent
        let multi = all.count > 1
        let count = present.reduce(0) { $0 + (census[$1] ?? 0) }
        PaneTypeFilterRow(
            title: family.title,
            detail: multi ? nil : all.first.map { $0.isEmpty ? "" : ".\($0)" },
            count: count,
            tick: PaneTypeFilter.tick(of: family, in: filter, census: census),
            disclosure: multi ? expanded.contains(family) : nil,
            onDisclose: {
                if expanded.contains(family) { expanded.remove(family) } else { expanded.insert(family) }
            },
            onToggle: { control.filter.wrappedValue = PaneTypeFilter.toggling(family, in: filter, census: census) },
            onOnly: { control.filter.wrappedValue = PaneTypeFilter.only(family, census: census) })
        if multi, expanded.contains(family) {
            ForEach(all, id: \.self) { ext in
                PaneTypeFilterRow(
                    title: ".\(ext)", isExtension: true,
                    count: census[ext] ?? 0,
                    tick: PaneTypeFilter.isTicked(ext, in: filter) ? .on : .off,
                    onToggle: {
                        control.filter.wrappedValue = PaneTypeFilter.toggling(extension: ext, in: filter, census: census)
                    },
                    onOnly: { control.filter.wrappedValue = PaneTypeFilter.only(extension: ext, census: census) })
                .padding(.leading, 22)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = footnote {
                Text(line)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let onUseOnBothPanes = control.onUseOnBothPanes {
                    Button("Use on Both Panes", action: onUseOnBothPanes)
                }
                Spacer()
                Button("Clear Filter") { control.filter.wrappedValue = nil }
                    .disabled(filter == nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// What the counts could not cover (TE270).
    var footnote: String? {
        var parts: [String] = []
        if control.isListing { parts.append("Still listing, counts may grow.") }
        let unexplored = control.facts?.unexploredCount ?? 0
        if unexplored > 0 {
            parts.append(unexplored == 1
                         ? "1 folder not looked inside isn’t counted."
                         : "\(unexplored.formatted()) folders not looked inside aren’t counted.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// One row of the type list: checkbox, title, count, and Only on hover or focus.
struct PaneTypeFilterRow: View {
    var title: String
    var isExtension = false
    var detail: String? = nil
    var count: Int
    var tick: PaneTypeFilter.Tick
    /// `nil` for a row with nothing to disclose; otherwise whether it is open.
    var disclosure: Bool? = nil
    var onDisclose: () -> Void = {}
    var onToggle: () -> Void
    var onOnly: () -> Void
    @State private var hovering = false
    @FocusState private var onlyFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let disclosure {
                Button(action: onDisclose) {
                    Image(systemName: "chevron.right")
                        .scaledFont(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(disclosure ? "Hide the extensions" : "Show the extensions")
                .accessibilityLabel(disclosure ? "Hide \(title) extensions" : "Show \(title) extensions")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: tick == .on ? "checkmark.square.fill"
                          : tick == .mixed ? "minus.square.fill" : "square")
                        // A filled box is a fill, so the window's deepened accent, never `.tint`
                        // (the system's) or the raw hue (2.7:1 under white on Green).
                        .foregroundStyle(tick == .off ? AnyShapeStyle(.secondary)
                                                      : AnyShapeStyle(LiquidGlassHue.stored().accentFillColor))
                    Text(title)
                        .font(isExtension ? .system(.body, design: .monospaced).weight(.regular) : nil)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).foregroundStyle(.secondary).monospaced()
                    }
                    Spacer(minLength: 4)
                    Text(count.formatted())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(tick == .on ? "On" : tick == .mixed ? "Some" : "Off")
            .accessibilityHint("\(count.formatted()) \(count == 1 ? "file" : "files")")
            Button("Only", action: onOnly)
                .buttonStyle(.plain)
                .foregroundStyle(LiquidGlassHue.stored().accentColor)
                .scaledFont(.system(size: 11))
                .focused($onlyFocused)
                .opacity(hovering || onlyFocused ? 1 : 0)
                .help("Show only \(title)")
                .accessibilityLabel("Show only \(title)")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
    }
}

/// The type filter as menu items, for the ⋯ menu when the button folds away and for View ▸ Filter
/// by Type (TE280): one checkmark per kind present, then Show All.
public struct PaneTypeFilterMenuItems: View {
    let control: PaneTypeFilterControl

    public init(control: PaneTypeFilterControl) {
        self.control = control
    }

    public var body: some View {
        let census = control.facts?.census ?? [:]
        let filter = control.filter.wrappedValue
        ForEach(PaneTypeFilter.presentFamilies(in: census), id: \.self) { family in
            Toggle(family.title, isOn: Binding(
                get: { PaneTypeFilter.tick(of: family, in: filter, census: census) != .off },
                set: { _ in control.filter.wrappedValue = PaneTypeFilter.toggling(family, in: filter, census: census) }))
        }
        Divider()
        Button("Show All") { control.filter.wrappedValue = nil }
            .disabled(filter == nil)
    }
}

/// What a pane's rows need from its type filter: which folders hold matches, and the noun to count
/// them in. Compared by the publish stamp and the filter, never by the dictionary — the counts are
/// a function of exactly those two, and comparing thousands of entries per render is the cost
/// `PaneTree` exists to avoid.
public struct PaneTypeFilterDecor: Equatable {
    public var stamp: Int
    public var filter: PaneTypeFilter
    public var matchCounts: [String: Int]

    public init(stamp: Int, filter: PaneTypeFilter, matchCounts: [String: Int]) {
        self.stamp = stamp
        self.filter = filter
        self.matchCounts = matchCounts
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stamp == rhs.stamp && lhs.filter == rhs.filter
    }

    /// A closed folder's pill, or nil (TE269).
    func phrase(forFolder path: String) -> String? {
        guard let count = matchCounts[path], count > 0 else { return nil }
        return filter.countPhrase(count)
    }
}
