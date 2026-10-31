import AppKit
import Design
import SwiftUI
import Sync

/// The colours the design page gives the two sides: iCloud, the source, teal; Dropbox, the copy,
/// slate. A held row is amber.
enum OneWaySyncPalette {
    static let source = Color(red: 0.05, green: 0.48, blue: 0.45)
    static let copy = Color(red: 0.32, green: 0.38, blue: 0.48)
    static let hold = SemanticColor.warning
    static let ok = SemanticColor.success
}

// MARK: - The status pill (ED, TE250)

/// **One-way sync's pill in Compare's differences bar**, beside the count (decision ED): "One-Way
/// Sync: Off · Set Up…" before setup, then the first rung of the ladder that applies. A click opens
/// setup, or the sync's overview.
public struct OneWaySyncStatusPill: View {
    @ObservedObject var controller: OneWaySyncController
    @ObservedObject var center: ActivityCenter
    let onSetUp: () -> Void

    /// The widest the pill draws: what the differences bar reserves for it.
    public static let maxWidth: CGFloat = 230

    public init(controller: OneWaySyncController = .shared, center: ActivityCenter = .shared, onSetUp: @escaping () -> Void) {
        self.controller = controller
        self.center = center
        self.onSetUp = onSetUp
    }

    var title: String {
        guard let ladder = controller.ladder else { return "One-Way Sync: Off · Set Up…" }
        if let activity = controller.activity { return activity }
        // Short: the bar is narrow, and the overview has the rest.
        switch ladder {
        case .upToDate(let asOf, let skipped):
            let when = Calendar.current.isDateInToday(asOf) ? "at " + asOf.formatted(date: .omitted, time: .shortened)
                                                           : asOf.formatted(.dateTime.day().month(.abbreviated))
            return "Synced \(when)" + (skipped > 0 ? " · \(skipped) skipped" : "") + " · Sync Now"
        case .notYetSynced: return "Not synced yet · Sync Now"
        default: return ladder.title()
        }
    }

    var color: Color {
        switch controller.ladder {
        case .none: return OneWaySyncPalette.copy
        case .stopped?, .needsYou?: return OneWaySyncPalette.hold
        case .upToDate?: return OneWaySyncPalette.ok
        default: return OneWaySyncPalette.copy
        }
    }

    public var body: some View {
        if controller.refusal == nil || controller.isSetUp {
            Button {
                if controller.ladder == nil { onSetUp() } else { controller.open(.overview, from: .main) }
            } label: {
                HStack(spacing: 6) {
                    if controller.activity != nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                    Text(title).lineLimit(1).truncationMode(.tail)
                }
                .scaledFont(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help(controller.ladder == nil ? "Keep a Dropbox folder a copy of an iCloud folder"
                                           : "One-way sync, iCloud to Dropbox: what it’s doing, Sync Now and Pause")
            .accessibilityLabel("One-way sync: \(title)")
        }
    }
}

// MARK: - The Syncs section of Compare's sidebar (ED, TE251)

/// **Compare's sidebar lists the sync** (decision ED): the pair and its state, a click away from
/// its overview, or *Add a Sync…* before there is one.
public struct OneWaySyncSidebarSection: View {
    @ObservedObject var controller: OneWaySyncController
    @ObservedObject var center: ActivityCenter
    let onSetUp: () -> Void

    public init(controller: OneWaySyncController = .shared, center: ActivityCenter = .shared, onSetUp: @escaping () -> Void) {
        self.controller = controller
        self.center = center
        self.onSetUp = onSetUp
    }

    public var body: some View {
        if controller.refusal == nil || controller.isSetUp {
            VStack(alignment: .leading, spacing: 2) {
                Text("Syncs")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                if let record = controller.record {
                    Button { controller.open(.overview, from: .main) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle").foregroundStyle(OneWaySyncPalette.source)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("iCloud → Dropbox").lineLimit(1)
                                Text(OneWaySyncSetupSheet.displayName(URL(fileURLWithPath: record.iCloudParent.path), side: .iCloud))
                                    .scaledFont(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 4)
                            if let ladder = controller.ladder {
                                Circle().fill(ladder.isProblem ? OneWaySyncPalette.hold : OneWaySyncPalette.ok).frame(width: 6, height: 6)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .help(controller.ladder?.title() ?? "One-way sync")
                } else {
                    Button("Add a Sync…", action: onSetUp)
                        .buttonStyle(.link)
                        .padding(.horizontal, 12)
                        .help("Keep a Dropbox folder a copy of an iCloud folder")
                }
            }
            .scaledFont(.system(size: 12))
        }
    }
}

// MARK: - The panes' role chips

/// **A pane's role in the sync**, in plain words (decision EF): *Changes made here* on iCloud's
/// side, *Kept as a copy* on Dropbox's.
public struct OneWaySyncRoleChip: View {
    let role: OneWaySyncPaneRole

    public init(_ role: OneWaySyncPaneRole) {
        self.role = role
    }

    public var body: some View {
        let color = role == .source ? OneWaySyncPalette.source : OneWaySyncPalette.copy
        HStack(spacing: 4) {
            Image(systemName: role == .source ? "pencil" : "lock.fill")
                .imageScale(.small)
                .foregroundStyle(color)
            Text(role == .source ? "Changes made here" : "Kept as a copy")
                .lineLimit(1)
        }
        .scaledFont(.system(size: 10, weight: .semibold))
        // The words in ink, the colour in the wash and the glyph (DS1).
        .foregroundStyle(.primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
        .help(role == .source
              ? "One-way sync copies this folder to Dropbox. Change files here."
              : "One-way sync keeps this a copy of iCloud. Synced files are changed in iCloud; files only in Dropbox are yours to change.")
        .accessibilityLabel(role == .source ? "One-way sync: changes made here go to Dropbox" : "One-way sync: kept as a copy of iCloud")
    }
}

// MARK: - Activity ▸ Now

/// **Activity ▸ Now's one-way sync rows**: *Needs you*, then *For your information* (DC). A row
/// under *Needs you* stays until answered or its cause clears; an information row has Dismiss.
public struct OneWaySyncNowRows: View {
    @ObservedObject var center: ActivityCenter
    @ObservedObject var controller: OneWaySyncController
    let host: OneWaySyncSheetHost

    public init(center: ActivityCenter = .shared, controller: OneWaySyncController = .shared, host: OneWaySyncSheetHost) {
        self.center = center
        self.controller = controller
        self.host = host
    }

    public var body: some View {
        let needsYou = center.oneWaySync.needsYou
        let information = center.oneWaySync.information
        if !needsYou.isEmpty || !information.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if !needsYou.isEmpty {
                    header("Needs you · \(needsYou.count)")
                    ForEach(Array(needsYou.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 12) }
                        rowView(title: row.title, detail: row.detail, raisedAt: row.raisedAt, held: true, id: row.id) {
                            ForEach(row.buttons, id: \.self) { button in
                                Button(button.title) { controller.perform(button, row: row, from: host) }
                                    .disabled(disabled(button))
                            }
                        }
                    }
                }
                if !information.isEmpty {
                    header("For your information")
                    ForEach(Array(information.enumerated()), id: \.element.id) { index, notice in
                        if index > 0 { Divider().padding(.leading, 12) }
                        let row = OneWaySyncNoticeRow(notice)
                        rowView(title: notice.title, detail: notice.detail, raisedAt: notice.raisedAt, held: false, id: notice.id) {
                            ForEach(notice.buttons, id: \.self) { button in
                                Button(button.title) { controller.perform(button, row: row, from: host) }
                                    .disabled(disabled(button))
                            }
                            Button("Dismiss") { center.dismissOneWaySync(notice.id) }
                        }
                    }
                }
            }
        }
    }

    func disabled(_ button: OneWaySyncNoticeButton) -> Bool {
        switch button {
        case .retry, .syncNow: return controller.syncNowRefusal != nil
        default: return controller.isRunning && button != .openDropbox && button != .openICloudSettings && button != .showThem
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .scaledFont(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func rowView<Buttons: View>(title: String, detail: String?, raisedAt: Int64, held: Bool, id: String,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(held ? OneWaySyncPalette.hold : OneWaySyncPalette.copy)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { buttons() }
                    VStack(alignment: .leading, spacing: 4) { buttons() }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            Spacer(minLength: 4)
            Text(Date(timeIntervalSince1970: TimeInterval(raisedAt)), format: .dateTime.hour().minute())
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(held ? OneWaySyncPalette.hold.opacity(center.highlightedNotice == id ? 0.2 : 0.07) : Color.clear)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Activity ▸ History

/// **One-way sync's History entries** (DE): each sync that changed or held something, newest
/// first, with *Reverse in iCloud…* while it can be.
public struct OneWaySyncHistoryRows: View {
    @ObservedObject var controller: OneWaySyncController
    @State private var entries: [OneWaySyncHistoryEntry] = []
    @State private var expanded: Set<UUID> = []

    public init(controller: OneWaySyncController = .shared) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entries.isEmpty {
                Text("One-Way Sync")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(entries.prefix(30)) { entry in
                    Divider().padding(.leading, 12)
                    entryRow(entry)
                }
            }
        }
        .task(id: controller.state?.lastSyncAt) { load() }
    }

    func load() {
        entries = controller.store?.history.entries() ?? []
    }

    func headline(_ entry: OneWaySyncHistoryEntry) -> String {
        let done = entry.steps.filter { $0.status == .confirmed }.count
        let held = entry.held.count
        var parts: [String] = []
        if done > 0 || held == 0 { parts.append("Synced \(done)") }
        if held > 0 { parts.append("\(held) wait\(held == 1 ? "s" : "") for you") }
        if entry.finishedAt == nil { parts.append("cut short") }
        let when = Date(timeIntervalSince1970: TimeInterval(entry.startedAt)).formatted(date: .abbreviated, time: .shortened)
        return parts.joined(separator: " · ") + " · " + when
    }

    @ViewBuilder func entryRow(_ entry: OneWaySyncHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                } label: {
                    Label(headline(entry), systemImage: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                        .scaledFont(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                if controller.reversible(entry) {
                    Button("Reverse in iCloud…") { controller.open(.reverse(entry.id), from: .activity) }
                        .controlSize(.small)
                        .disabled(controller.isRunning)
                }
            }
            if expanded.contains(entry.id) {
                ForEach(Array(entry.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(OneWaySyncWords.kind(step.step.action))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text(OneWaySyncWords.paths(step.step.action))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(OneWaySyncWords.status(step.status))
                            .foregroundStyle(step.status == .confirmed ? OneWaySyncPalette.source : OneWaySyncPalette.hold)
                    }
                    .scaledFont(.system(size: 11))
                }
                ForEach(Array(entry.held.enumerated()), id: \.offset) { _, wait in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Waits").foregroundStyle(OneWaySyncPalette.hold).frame(width: 72, alignment: .leading)
                        Text(OneWaySyncWords.subject(wait.subject)).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                        Spacer(minLength: 4)
                    }
                    .scaledFont(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// How History and the sheets put a step into words.
enum OneWaySyncWords {
    static func kind(_ action: OneWaySyncAction) -> String {
        switch action {
        case .moveFolderInDropbox: return "Moved"
        case .moveInDropbox(let from, let to):
            return OneWaySyncPath.parent(from) == OneWaySyncPath.parent(to) ? "Renamed" : "Moved"
        case .moveToRemoved(_, let cause):
            if case .movedOutInICloud = cause { return "Moved out" }
            return "Deleted"
        case .replace: return "Edited"
        case .moveBackFromRemoved: return "Back"
        case .copy: return "Added"
        case .adopt: return "Same"
        case .setTags: return "Tags"
        case .forget: return "Gone"
        }
    }

    static func paths(_ action: OneWaySyncAction) -> String {
        switch action {
        case .moveFolderInDropbox(let from, let to), .moveInDropbox(let from, let to): return "\(from) → \(to)"
        case .moveToRemoved(let path, _), .setTags(let path, _), .forget(let path): return path
        case .replace(let path, _, _, _): return path
        case .moveBackFromRemoved(_, let to), .copy(_, let to, _): return to
        case .adopt(let path, _): return path
        }
    }

    static func status(_ status: OneWaySyncHistoryStep.Status) -> String {
        switch status {
        case .pending: return "Not started"
        case .started: return "Started"
        case .applied: return "Not yet uploaded"
        case .confirmed: return "Done"
        case .skipped(let why): return "Skipped: \(why)"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    static func subject(_ subject: OneWaySyncWait.Subject) -> String {
        switch subject {
        case .folder(let name): return name + "/"
        case .file(let i, let d): return i ?? d ?? ""
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - The pane's role line

/// **The line under a pane's header saying which side of one-way sync it shows** — with the role
/// chip, the way the cloud-app line sits there (TE236).
public struct OneWaySyncRoleLine: View {
    let role: OneWaySyncPaneRole

    public init(role: OneWaySyncPaneRole) {
        self.role = role
    }

    public var body: some View {
        HStack(spacing: 8) {
            OneWaySyncRoleChip(role)
            Text(role == .source ? "Sync Now copies them to Dropbox"
                                 : "Change synced files in iCloud · files only in Dropbox are yours")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
