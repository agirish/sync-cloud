import SwiftUI
import AppKit
import Design
import Events
import FileExplorer

/// One Activity window with two tabs. Events: what runs and needs you, on a band above everything
/// SyncCloud did, where a run is one row that opens to its files. Log: the lines it wrote, which a
/// row links down to by its minutes.
///
/// A row's Undo acts on the main window's undo stack; ⌘Z pressed in this window has a stack of its
/// own.
public struct ActivityWindow<Events: View>: View {
    @ObservedObject var center: ActivityCenter
    let activeProgress: Progress?
    let activeProgressStartedAt: Date?
    let runWriteLock: String?
    /// The long scans, listed under the runs.
    let scans: [ProgressCapsuleListedRun]
    let events: Events
    /// The window's hue for the tab picker's selection — the app's, never the system's.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    public init(center: ActivityCenter, activeProgress: Progress?, activeProgressStartedAt: Date?,
                runWriteLock: String?, scans: [ProgressCapsuleListedRun] = [],
                @ViewBuilder events: () -> Events) {
        self.center = center
        self.scans = scans
        self.activeProgress = activeProgress
        self.activeProgressStartedAt = activeProgressStartedAt
        self.runWriteLock = runWriteLock
        self.events = events()
    }

    /// What runs and needs you, ticking for the runs' progress and ages. Only this ticks: Events'
    /// timeline under it says times of day and never redraws on a clock.
    private var band: some View {
        ActivityRunsReader(activeProgress: activeProgress, activeProgressStartedAt: activeProgressStartedAt,
                           center: center) { entries in
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                ActivityNowView(runs: entries.map { $0.listed() } + scans, center: center,
                                runWriteLock: runWriteLock, now: timeline.date)
            }
        }
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
            // In the title bar's row, level with the traffic lights: the window's title is hidden,
            // so a band of its height above the tabs would be dead space.
            .frame(height: LogViewer.titleBarInset + 6)
            .accessibilityLabel("Activity")
            Divider().opacity(0.6)
            switch center.tab {
            case .events:
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        // What runs and needs you: at most a third of the window, scrolling inside
                        // itself past that, so the timeline always keeps room. Only the band ticks.
                        ScrollView { band }
                            .frame(maxHeight: proxy.size.height / 3)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().opacity(0.6)
                        events
                    }
                }
            case .log:
                LogViewer(span: $center.logSpan, showsTitle: false)
            }
        }
        // Pinned to the top, so the tabs never drift down a tall window.
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .top)
        // At Clear, the same ground Settings' card gives its text, between the content and the
        // glass below, so the two read alike.
        .clearWindowGround(level: GlassLevel(rawValue: glassLevelRaw) ?? .frosted)
        // One ground for both tabs: the main window's glass, at its level and hue. Without
        // it, at Clear the tabs and the band show the window behind straight through.
        .liquidGlassAppBackground(level: GlassLevel(rawValue: glassLevelRaw) ?? .frosted,
                                  hue: LiquidGlassHue(rawValue: glassHueRaw) ?? .blue, tint: surfaceTint)
        // Keep the glass from greying out when this window isn't key, as the main window does.
        .environment(\.controlActiveState, .active)
        // Opening Activity is seeing it: the toolbar's dot goes.
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
