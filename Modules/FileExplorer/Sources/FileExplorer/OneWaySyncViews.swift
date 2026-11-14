import AppKit
import Design
import SwiftUI
import Sync

/// The colours the design page gives the two sides: iCloud, the source, teal; Dropbox, the copy,
/// slate, each in its light and dark form from the page, so ink and glyphs read in both
/// appearances (`OneWaySyncPaletteTests` measures them). A held row is amber.
enum OneWaySyncPalette {
    static let sourceNS = dynamic(light: (0.05, 0.48, 0.45), dark: (0.31, 0.77, 0.73))
    static let copyNS = dynamic(light: (0.32, 0.38, 0.48), dark: (0.62, 0.69, 0.81))
    static let source = Color(nsColor: sourceNS)
    static let copy = Color(nsColor: copyNS)
    /// Text in the source's colour: the same teal, which clears the body-text floor in both.
    static let sourceInk = source
    static let hold = SemanticColor.warning
    static let ok = SemanticColor.success

    static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}

// MARK: - The status pill (ED, TE250)

/// One-way sync's pill in Compare's differences bar, beside the count: "One-Way Sync: Off ·
/// Set Up…" before setup, then the first rung of the ladder that applies. A click opens setup, or
/// the sync's overview.
public struct OneWaySyncStatusPill: View {
    @ObservedObject var controller: OneWaySyncController
    @ObservedObject var center: ActivityCenter
    let onSetUp: () -> Void
    /// The app's accent, for the pill's suggestion to sync after changes.
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue

    /// The widest the pill draws at the app's own text size; longer words truncate, whole in the
    /// tooltip. What it says decides what the bar reserves (`width`), never this cap alone.
    public static let maxWidth: CGFloat = 300
    static let font = ScaledFont.system(size: 11, weight: .medium)
    /// The dot, its gap and the capsule's padding around the words.
    static let chrome: CGFloat = 7 + 6 + 2 * 9

    public init(controller: OneWaySyncController = .shared, center: ActivityCenter = .shared, onSetUp: @escaping () -> Void) {
        self.controller = controller
        self.center = center
        self.onSetUp = onSetUp
    }

    var title: String { Self.title(controller.ladder) }

    /// What the differences bar reserves for the pill at `scale`: its words as they are now, the
    /// dot and the capsule, up to `maxWidth`; nothing when it draws nothing (a copy that may not
    /// sync, never set up). Priced from the words so a short "3 need you" doesn't take a stop
    /// reason's room from Verify and Review.
    @MainActor public static func width(controller: OneWaySyncController = .shared, scale: CGFloat) -> CGFloat {
        guard controller.refusal == nil || controller.isSetUp else { return 0 }
        let words = LabelMetrics.width(of: title(controller.ladder), font: font, scale: scale)
        return min(words + chrome * scale, maxWidth * scale).rounded(.up)
    }

    /// Whether Compare's bar carries the pill: always once the sync is set up (or another Mac
    /// syncs, or it stopped), and before that only for a comparison of an iCloud Drive pane with
    /// a Dropbox one, where setting it up is the next thing. Never for a copy that may not sync and
    /// was never set up.
    @MainActor public static func isShown(controller: OneWaySyncController = .shared, paneTypes: [CloudProvider.ProviderType?]) -> Bool {
        guard controller.refusal == nil || controller.isSetUp else { return false }
        if controller.isSetUp || controller.otherMac != nil || controller.stop != nil { return true }
        return paneTypes.contains(.iCloud) && paneTypes.contains(.dropBox)
    }

    static func title(_ ladder: OneWaySyncLadder?) -> String {
        guard let ladder else { return "One-Way Sync: Off · Set Up…" }
        // Short: the bar is narrow, and the overview has the rest.
        func day(_ date: Date) -> String {
            Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                                 : date.formatted(.dateTime.day().month(.abbreviated))
        }
        switch ladder {
        case .upToDate(let asOf, let skipped):
            let when = Calendar.current.isDateInToday(asOf) ? "at " + day(asOf) : day(asOf)
            return "Synced \(when)" + (skipped > 0 ? " · \(skipped) skipped" : "") + " · Sync Now"
        // The watcher suggests a sync; only the button runs one.
        case .changes(let count, let since):
            return (count == 1 ? "1 change" : "\(count.formatted()) changes") + " since \(day(since)) · Sync Now"
        case .changesMayBeWaiting: return "Changes may be waiting · Sync Now"
        case .notYetSynced: return "Not synced yet · Sync Now"
        case .needsYou: return ladder.title() + " · Review…"
        default: return ladder.title()
        }
    }

    var color: Color {
        switch controller.ladder {
        case .none: return OneWaySyncPalette.copy
        case .stopped?, .needsYou?: return OneWaySyncPalette.hold
        case .upToDate?: return OneWaySyncPalette.ok
        case .changes?, .changesMayBeWaiting?: return (LiquidGlassHue(rawValue: hueRaw) ?? .blue).accentColor
        default: return OneWaySyncPalette.copy
        }
    }

    public var body: some View {
        if controller.refusal == nil || controller.isSetUp {
            Button {
                if controller.ladder == nil { onSetUp() } else { controller.open(.overview, from: .main) }
            } label: {
                HStack(spacing: 6) {
                    if case .syncing? = controller.ladder {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                    // "Synced at 14:02" becomes "Synced 31 Oct" after midnight, "2 h ago" moves on.
                    TimelineView(.everyMinute) { _ in Text(title).lineLimit(1).truncationMode(.tail) }
                }
                .scaledFont(Self.font)
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
            }
            .buttonStyle(.plain)
            // The whole of what it says, which the bar may cut short.
            .help(controller.ladder == nil ? "\(title): keep a Dropbox folder a copy of an iCloud folder"
                                           : "\(title) — one-way sync, iCloud to Dropbox: what it’s doing, Sync Now and Pause")
            .accessibilityLabel("One-way sync: \(title)")
        }
    }
}

// MARK: - The Syncs section of Compare's sidebar (ED, TE251)

/// Compare's sidebar entry for the sync: the pair and its state, a click away from its overview,
/// or *Add a Sync…* before there is one.
public struct OneWaySyncSidebarSection: View {
    @ObservedObject var controller: OneWaySyncController
    @ObservedObject var center: ActivityCenter
    let onSetUp: () -> Void
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue

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
                    .padding(.horizontal, 10)
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
                            // The count of what needs you; a dot for any other state.
                            if case .needsYou(let count)? = controller.ladder {
                                Text(count.formatted())
                                    .scaledFont(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(OneWaySyncPalette.hold)
                                    .monospacedDigit()
                            } else if case .changes(let count, _)? = controller.ladder {
                                // What changed since the last sync, in the accent: a suggestion, not a problem.
                                Text(count.formatted())
                                    .scaledFont(.system(size: 11, weight: .semibold))
                                    .foregroundStyle((LiquidGlassHue(rawValue: hueRaw) ?? .blue).accentColor)
                                    .monospacedDigit()
                            } else if case .changesMayBeWaiting? = controller.ladder {
                                Circle().fill((LiquidGlassHue(rawValue: hueRaw) ?? .blue).accentFillColor).frame(width: 6, height: 6)
                            } else if let ladder = controller.ladder {
                                Circle().fill(ladder.isProblem ? OneWaySyncPalette.hold : OneWaySyncPalette.ok).frame(width: 6, height: 6)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .help(controller.ladder?.title() ?? "One-way sync")
                    .accessibilityLabel("iCloud to Dropbox: \(controller.ladder?.title() ?? "one-way sync")")
                } else {
                    Button("Add a Sync…", action: onSetUp)
                        .buttonStyle(.link)
                        .padding(.horizontal, 10)
                        .help("Keep a Dropbox folder a copy of an iCloud folder")
                }
            }
            .scaledFont(.system(size: 12))
        }
    }
}

// MARK: - The panes' role chips

/// A pane's role in the sync, in plain words: *Changes made here* on iCloud's side, *Kept as a
/// copy* on Dropbox's.
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
        // The words in ink, the colour in the wash and the glyph.
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

// MARK: - Above Activity ▸ Events

/// One-way sync's rows above Activity ▸ Events: *Needs you*, then *For your information*. A row under
/// *Needs you* stays until answered or its cause clears; an information row has Dismiss.
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
                                Button(button.title(on: row)) { controller.perform(button, row: row, from: host) }
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
            // A row stays until answered, days if need be: past today it says the day too.
            Text(OneWaySyncWords.when(Date(timeIntervalSince1970: TimeInterval(raisedAt)), now: Date()))
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

// MARK: - Activity ▸ Events

/// One one-way sync in Activity's Events: what it changed and held, opened in place, with
/// *Reverse in iCloud…* while it can be.
public struct OneWaySyncHistoryEntryRow: View {
    let entry: OneWaySyncHistoryEntry
    @ObservedObject var controller: OneWaySyncController
    @State private var isExpanded = false

    public init(entry: OneWaySyncHistoryEntry, controller: OneWaySyncController = .shared) {
        self.entry = entry
        self.controller = controller
    }

    /// When it ran, for its place in the timeline.
    public static func date(_ entry: OneWaySyncHistoryEntry) -> Date {
        Date(timeIntervalSince1970: TimeInterval(entry.startedAt))
    }

    /// "Synced 4 · 32 wait for you": the changes a sync made, never the files it found already the
    /// same. The row's time stands beside it.
    public static func headline(_ entry: OneWaySyncHistoryEntry) -> String {
        let done = changedSteps(entry).filter { $0.status == .confirmed }.count
        let held = entry.held.count
        var parts: [String] = []
        if done > 0 || held == 0 { parts.append("Synced \(done.formatted())") }
        if held > 0 { parts.append("\(held.formatted()) wait\(held == 1 ? "s" : "") for you") }
        if entry.finishedAt == nil { parts.append("cut short") }
        return parts.joined(separator: " · ")
    }

    /// Whether Events' filter field finds it: in its headline, or in a path it changed or held.
    public static func matches(_ entry: OneWaySyncHistoryEntry, search: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if "One-way sync \(headline(entry))".localizedCaseInsensitiveContains(needle) { return true }
        return changedSteps(entry).contains { OneWaySyncWords.paths($0.step).localizedCaseInsensitiveContains(needle) }
            || entry.held.contains { OneWaySyncWords.subject($0.subject).localizedCaseInsensitiveContains(needle) }
    }

    private static func changedSteps(_ entry: OneWaySyncHistoryEntry) -> [OneWaySyncHistoryStep] {
        entry.steps.filter { OneWaySyncWords.isChange($0.step.action) }
    }

    public var body: some View {
        let changed = Self.changedSteps(entry)
        let lines = changed.count + entry.held.count
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(entry.held.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(OneWaySyncPalette.hold))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("One-way sync: \(Self.headline(entry))")
                        .scaledFont(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(Self.date(entry).formatted(date: .omitted, time: .shortened))
                        .scaledFont(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text("iCloud → Dropbox")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if lines > 0 {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Label(lines == 1 ? "1 change" : "\(lines.formatted()) changes",
                                  systemImage: isExpanded ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.link)
                        .accessibilityValue(isExpanded ? "Open" : "Closed")
                        .help(isExpanded ? "Hide what this sync changed" : "Show what this sync changed")
                    }
                    if controller.reversible(entry) {
                        Button("Reverse in iCloud…") { controller.open(.reverse(entry.id), from: .activity) }
                            .disabled(controller.isRunning)
                    }
                }
                .controlSize(.small)
                .scaledFont(.system(size: 11))
                if isExpanded {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(changed.enumerated()), id: \.offset) { _, step in
                            line(OneWaySyncWords.kind(step.step), OneWaySyncWords.paths(step.step), OneWaySyncWords.outcome(step),
                                 held: step.status != .confirmed)
                        }
                        let same = entry.steps.filter { if case .adopt = $0.step.action { return true } else { return false } }.count
                        if same > 0 {
                            line("Same", same == 1 ? "1 file already the same" : "\(same.formatted()) files already the same", "Recorded", held: false)
                        }
                        ForEach(Array(entry.held.enumerated()), id: \.offset) { _, wait in
                            line("Waits", OneWaySyncWords.subject(wait.subject), OneWaySyncWords.why(wait.reason), held: true)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func line(_ kind: String, _ paths: String, _ outcome: String, held: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(kind)
                .foregroundStyle(held ? OneWaySyncPalette.hold : .secondary)
                .frame(width: 72, alignment: .leading)
            Text(paths)
                .scaledFont(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(outcome)
                .foregroundStyle(held ? OneWaySyncPalette.hold : OneWaySyncPalette.sourceInk)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .scaledFont(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}

/// How History and the sheets put a step into words.
enum OneWaySyncWords {
    /// A step: a copy of a file moved in from a folder that isn't synced reads as the move.
    static func kind(_ step: OneWaySyncStep) -> String {
        if step.movedInFrom != nil, case .copy = step.action { return "Moved in" }
        return kind(step.action)
    }

    static func paths(_ step: OneWaySyncStep) -> String {
        if let origin = step.movedInFrom, case .copy(_, let to, _) = step.action { return "\(origin) → \(to)" }
        return paths(step.action)
    }

    /// Whether a step changed anything in Dropbox: adopting a file already the same and
    /// forgetting one gone from both sides only change the record.
    static func isChange(_ action: OneWaySyncAction) -> Bool {
        switch action {
        case .adopt, .forget: return false
        default: return true
        }
    }

    /// What a step did, as History's right-hand column says it ("Renamed in Dropbox", "Folder
    /// moved · nothing uploaded"), or how far it got when it didn't finish.
    static func outcome(_ step: OneWaySyncHistoryStep) -> String {
        guard step.status == .confirmed else { return status(step.status) }
        switch step.step.action {
        case .moveFolderInDropbox: return "Folder moved in Dropbox · nothing uploaded"
        case .moveInDropbox(let from, let to):
            return OneWaySyncPath.parent(from) == OneWaySyncPath.parent(to) ? "Renamed in Dropbox" : "Moved in Dropbox"
        case .moveToRemoved: return "Moved to SyncCloud Removed"
        case .replace:
            let emptied = step.emptied?.count ?? 0
            return "Replaced, the old one kept" + (emptied > 0 ? " · the oldest kept version went to Dropbox’s deleted files" : "")
        case .moveBackFromRemoved: return "Moved back from SyncCloud Removed"
        case .copy: return step.step.movedInFrom == nil ? "Copied" : "Copied, from a folder that isn’t synced"
        case .setTags: return "Tags set"
        case .adopt: return "Recorded"
        case .forget: return "Forgotten"
        }
    }

    /// Why a sync held something, in the words of its rows above Events.
    static func why(_ reason: OneWaySyncWaitReason) -> String {
        switch reason {
        case .overRemovalLimit, .overRemovalLimitAcrossFolders: return "Over the removal limit"
        case .syncedFolderRenamedInICloud: return "Rename Dropbox’s too?"
        case .syncedFolderMovedOrDeletedInICloud: return "Moved or deleted in iCloud"
        default:
            let words = OneWaySyncRun.words(reason)
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    static func kind(_ action: OneWaySyncAction) -> String {
        switch action {
        case .moveFolderInDropbox(let from, let to):
            return OneWaySyncPath.parent(from) == OneWaySyncPath.parent(to) ? "Renamed" : "Moved"
        case .moveInDropbox(let from, let to):
            return OneWaySyncPath.parent(from) == OneWaySyncPath.parent(to) ? "Renamed" : "Moved"
        case .moveToRemoved(_, let cause):
            if case .movedOutInICloud = cause { return "Moved out" }
            if case .refusedCopy = cause { return "Removed" }
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
        case .moveFolderInDropbox(let from, let to): return "\(from)/ → \(to)/"
        case .moveInDropbox(let from, let to): return "\(from) → \(to)"
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

    /// A time as rows and sheets say it: "10:14" today ("today, 10:14" where it reads on its own),
    /// "yesterday, 10:14", "28 Oct, 10:14", and with the year once it isn't this one.
    static func when(_ date: Date, now: Date, saysToday: Bool = false, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return saysToday ? "today, " + time : time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday, " + time
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? date.formatted(.dateTime.day().month(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated).year())
        return day + ", " + time
    }
}

// MARK: - The pane's role line

/// The line under a pane's header saying which side of one-way sync it shows, with the role chip,
/// the way the cloud-app line sits there.
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
