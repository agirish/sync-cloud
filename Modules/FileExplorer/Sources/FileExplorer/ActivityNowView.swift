import SwiftUI
import Design
import Sync

extension OperationBanner.FollowUp {
    /// The button's words — the same in a pane's message and in Recent.
    public var title: String {
        switch self {
        case .openInEdit: return "Open in Edit"
        case .revealInBrowse: return "Reveal in Browse"
        case .download: return "Download"
        }
    }

    /// Its tooltip, naming the file — or how many — it goes to.
    public var help: String {
        func name(_ path: String) -> String { "“\((path as NSString).lastPathComponent)”" }
        switch self {
        case .openInEdit(let path): return "Open \(name(path)) in Edit"
        case .revealInBrowse(let paths):
            return paths.count == 1 ? "Show \(name(paths[0])) in Browse" : "Show the \(paths.count) files in Browse"
        case .download: return "Download the file from the cloud, then try again"
        }
    }

    /// The files it would open — a door to files moved or deleted since goes nowhere.
    var paths: [String] {
        switch self {
        case .openInEdit(let path), .download(let path): return [path]
        case .revealInBrowse(let paths): return paths
        }
    }
}

/// **Activity's Now: what is running, and what was said** (TE220, TE221, TE222) — the capsule's
/// popover, and the Activity window's first tab. The same rows in both, read off ``ActivityCenter``.
public struct ActivityNowView: View {
    let runs: [ProgressCapsuleListedRun]
    @ObservedObject var center: ActivityCenter
    /// The cloud app status (RD68), whose rows Now lists.
    @ObservedObject var cloudApps: CloudAppMonitor
    /// Why writes wait while a long run goes — a row's Undo waits too (decision CF).
    let runWriteLock: String?
    /// The popover's foot, "Open as Window"; the window itself has none.
    let onOpenWindow: (() -> Void)?
    /// What "2 min ago" is counted from — the host's timeline tick.
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(runs: [ProgressCapsuleListedRun], center: ActivityCenter, runWriteLock: String?,
                now: Date = Date(), cloudApps: CloudAppMonitor = .shared, onOpenWindow: (() -> Void)? = nil) {
        self.runs = runs
        self.center = center
        self.cloudApps = cloudApps
        self.runWriteLock = runWriteLock
        self.onOpenWindow = onOpenWindow
        self.now = now
    }

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue

    public var body: some View {
        if let onOpenWindow {
            popover(onOpenWindow)
        } else {
            window
        }
    }

    /// The capsule's popover: one column, the capsule's width, as tall as its rows to a point.
    private func popover(_ onOpenWindow: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            running(fillsWidth: false)
            Divider()
            if !cloudApps.notices.isEmpty {
                CloudAppNoticeRows(monitor: cloudApps)
                Divider()
            }
            recentHeader
            if center.recent.isEmpty {
                nothingYet
            } else {
                ScrollView { recentRows }
                    .frame(maxHeight: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("Kept until SyncCloud quits")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open as Window", action: onOpenWindow)
                    .buttonStyle(.link)
            }
            .scaledFont(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: ProgressCapsuleRunList.width, alignment: .leading)
    }

    /// The Activity window's Now: Running and Recent each on a card of the window's glass, as the
    /// panes sit on the main window's — Recent taking the rest of the height.
    private var window: some View {
        let level = GlassLevel(rawValue: glassLevelRaw) ?? .frosted
        return VStack(spacing: 12) {
            running(fillsWidth: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(level, cornerRadius: Radius.card)
            // A cloud app not syncing (RD68): information, between what runs and what was said.
            if !cloudApps.notices.isEmpty {
                CloudAppNoticeRows(monitor: cloudApps)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(level, cornerRadius: Radius.card)
            }
            VStack(alignment: .leading, spacing: 0) {
                recentHeader
                if center.recent.isEmpty {
                    nothingYet
                    Spacer(minLength: 0)
                } else {
                    // A notification's click brings its row into view (TE227).
                    ScrollViewReader { proxy in
                        ScrollView { recentRows }
                            .onChange(of: center.highlighted, initial: true) { _, id in
                                guard let id else { return }
                                withDesignAnimation(.default, reduceMotion: reduceMotion) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassSurface(level, cornerRadius: Radius.card)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func running(fillsWidth: Bool) -> some View {
        if runs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                section("Running")
                Text("Nothing running")
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, 2)
            }
        } else {
            // The window is wide and opened to read: its keys are not the runs' (only the popover's).
            ProgressCapsuleRunList(runs: runs, fillsWidth: fillsWidth, takesKeys: !fillsWidth)
        }
    }

    private var recentHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            section("Recent")
            Spacer()
            if !center.recent.isEmpty {
                Button("Clear") { center.clear() }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .padding(.trailing, 12)
                    .padding(.bottom, 4)
                    .help("Clear Recent — Sync History and the log keep their own records")
            }
        }
    }

    private var nothingYet: some View {
        Text("Nothing yet this session")
            .scaledFont(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 2)
    }

    private var recentRows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(center.recent.enumerated()), id: \.element.id) { index, message in
                if index > 0 { Divider().padding(.leading, 12) }
                ActivityRecentRow(message: message, center: center, runWriteLock: runWriteLock, now: now)
                    .background(message.id == center.highlighted
                                ? RoundedRectangle(cornerRadius: Radius.chip).fill(LiquidGlassHue.stored().accentColor.opacity(0.14))
                                : nil)
                    // A capsule message arriving while Activity is open flashes its row once. A
                    // fade, so Reduce Motion keeps it.
                    .keyframeAnimator(initialValue: 0.0, trigger: center.flashes) { row, glow in
                        row.background(RoundedRectangle(cornerRadius: Radius.chip)
                            .fill(LiquidGlassHue.stored().accentColor.opacity(message.id == center.flashedRow ? glow : 0)))
                    } keyframes: { _ in
                        LinearKeyframe(0.22, duration: 0.15)
                        LinearKeyframe(0, duration: 1.45)
                    }
                    .id(message.id)
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .scaledFont(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One message in Recent, in full: its sentence and detail line, when, and its buttons (TE222). Its
/// Undo is live only while its step is the newest (TE223).
struct ActivityRecentRow: View {
    let message: ActivityMessage
    @ObservedObject var center: ActivityCenter
    let runWriteLock: String?
    let now: Date

    /// "2 min. ago" — counted from the host's tick, so a row's age moves with the clock.
    static func age(of date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return now.timeIntervalSince(date) < 5 ? "now" : formatter.localizedString(for: date, relativeTo: now)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            // A stop is grey whatever it saved — the reader ended it (TE221).
            Image(systemName: message.isStopped ? "stop.circle.fill" : Self.symbol(message.severity))
                .foregroundStyle(message.isStopped ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.tint(message.severity)))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.message)
                        .scaledFont(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if message.repeats > 1 {
                        Text("×\(message.repeats)")
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(Self.age(of: message.date, now: now))
                        .scaledFont(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let detail = message.detail {
                    Text(detail)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        let followUps = message.followUps
        let hasUndo = message.undoStep != nil
        if hasUndo || !followUps.isEmpty || message.runId != nil || message.source == .window {
            HStack(spacing: 6) {
                if hasUndo {
                    let refusal = runWriteLock ?? center.undoRefusal(for: message)
                    Button {
                        center.undo(message)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(refusal != nil)
                    .help(refusal ?? "Undo this operation")
                }
                ForEach(Array(followUps.enumerated()), id: \.offset) { _, followUp in
                    let here = PaneToolResult.stillThere(followUp.paths)
                    Button(followUp.title) { open(followUp, here: here) }
                        .disabled(here.isEmpty && !Self.isDownload(followUp))
                        .help(here.isEmpty && !Self.isDownload(followUp)
                              ? PaneToolResult.goneMessage(followUp.paths) : followUp.help)
                }
                if let runId = message.runId {
                    Button("Show in History") { center.doors.showInHistory(runId) }
                        .buttonStyle(.link)
                        .help("Sync History, narrowed to this run’s records")
                }
                if message.source == .window {
                    Button("Show in Log") { center.doors.showInLog(message.span) }
                        .buttonStyle(.link)
                        .help("The log, narrowed to the minutes around this message")
                }
            }
            .controlSize(.small)
            .scaledFont(.system(size: 11))
        }
    }

    private func open(_ followUp: OperationBanner.FollowUp, here: [String]) {
        switch followUp {
        case .openInEdit: if let path = here.first { center.doors.openInEdit(path) }
        case .revealInBrowse: center.doors.reveal(here)
        case .download(let path): center.doors.download(path)
        }
    }

    private static func isDownload(_ followUp: OperationBanner.FollowUp) -> Bool {
        if case .download = followUp { return true }
        return false
    }

    static func symbol(_ severity: OperationBanner.Severity) -> String {
        switch severity {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    static func tint(_ severity: OperationBanner.Severity) -> Color {
        switch severity {
        case .success: return SemanticColor.success
        case .warning: return SemanticColor.warning
        case .error: return SemanticColor.error
        }
    }
}
