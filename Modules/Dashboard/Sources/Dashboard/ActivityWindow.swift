import SwiftUI
import AppKit
import Design
import Events
import FileExplorer

/// **One Activity window: Now · History · Log** (Run Room TE232, decision CR). What were three
/// windows answering "what did SyncCloud just do?" — the capsule's runs and messages, Sync History,
/// and the Activity Log — are three tabs of one, each at its own depth: a message is one sentence,
/// a run has its Sync History records, and it wrote its own lines to the log as it went. A Recent
/// row links down a level, to its run's records or to its minutes in the log (R13).
///
/// History and Log are the two windows' own views, unchanged but for their title rows, which the
/// tab replaces. A row's Undo here acts on the main window's undo stack (R12); ⌘Z pressed in this
/// window has a stack of its own, as Sync History's always had.
public struct ActivityWindow<History: View>: View {
    @ObservedObject var center: ActivityCenter
    let activeProgress: Progress?
    let activeProgressStartedAt: Date?
    let runWriteLock: String?
    /// The long scans, under the runs (TE228).
    let scans: [ProgressCapsuleListedRun]
    let history: History
    /// The window's hue for the tab picker's selection — the app's, never the system's.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    public init(center: ActivityCenter, activeProgress: Progress?, activeProgressStartedAt: Date?,
                runWriteLock: String?, scans: [ProgressCapsuleListedRun] = [],
                @ViewBuilder history: () -> History) {
        self.center = center
        self.scans = scans
        self.activeProgress = activeProgress
        self.activeProgressStartedAt = activeProgressStartedAt
        self.runWriteLock = runWriteLock
        self.history = history()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Activity", selection: $center.tab) {
                ForEach(ActivityTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accentedSegments(LiquidGlassHue(rawValue: glassHueRaw) ?? .blue)
            .fixedSize()
            .padding(.top, LogViewer.titleBarInset)
            .padding(.bottom, 8)
            .accessibilityLabel("Activity")
            Divider().opacity(0.6)
            switch center.tab {
            case .now:
                ActivityRunsReader(activeProgress: activeProgress, activeProgressStartedAt: activeProgressStartedAt,
                                   center: center) { entries in
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        ActivityNowView(runs: entries.map { $0.listed() } + scans, center: center,
                                        runWriteLock: runWriteLock, now: timeline.date)
                    }
                }
            case .history:
                history
            case .log:
                LogViewer(span: $center.logSpan, showsTitle: false)
            }
        }
        // From the top: Now is only as tall as its rows, and a window taller than them centred the
        // whole stack — tabs included — in it (seen on screen 2026-10-27).
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .top)
        // Opening Activity is seeing it: the toolbar's dot goes (CS).
        .onAppear { center.markSeen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix(ActivityCenter.windowID) == true
            else { return }
            _ = center.tabForOpening()
            center.markSeen()
        }
    }
}

/// "One run · 12 records ✕" — the filter a Recent row's link set, above the list it narrows, with
/// the way back to all of it.
struct ActivityFilterChip: View {
    let text: String
    let help: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .scaledFont(.system(size: 12, weight: .medium))
            Spacer()
            Button("Show All", action: onClear)
                .buttonStyle(.link)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .help(help)
        .accessibilityElement(children: .combine)
    }
}
