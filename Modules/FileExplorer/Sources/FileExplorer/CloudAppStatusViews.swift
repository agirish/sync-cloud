import AppKit
import SwiftUI
import Design
import Sync

/// **The amber line under a pane's header while its cloud app isn't syncing** (RD68). The files
/// below it still show, here and in Finder, and may be out of date; the line says so, and offers
/// the one thing that fixes it where there is one.
///
/// **One line, not a card** (his call TE236, 2026-10-30, over a chip, a floating pill and a toolbar
/// capsule): the card took two to six lines and pushed the list down. The line is about a third of
/// that and never wraps; the full sentence is its tooltip and what VoiceOver reads.
public struct CloudAppWarningBar: View {
    let problem: CloudAppProblem
    /// The source's name, for the states that have no app to name — iCloud's.
    let sourceName: String
    let canOpen: (CloudApp) -> Bool
    let onAction: (CloudAppNotice.Action) -> Void
    let now: Date

    public init(problem: CloudAppProblem, sourceName: String, canOpen: @escaping (CloudApp) -> Bool,
                now: Date = Date(), onAction: @escaping (CloudAppNotice.Action) -> Void) {
        self.problem = problem
        self.sourceName = sourceName
        self.canOpen = canOpen
        self.now = now
        self.onAction = onAction
    }

    /// The full sentence — the tooltip and VoiceOver's reading: the part in bold, then the rest. A
    /// value, so a test reads the words without a rendered bar.
    static func sentence(for problem: CloudAppProblem, sourceName: String, now: Date) -> (lead: String, rest: String) {
        switch problem {
        case .notRunning(let app):
            return ("The \(app.name) app isn’t running, so these files may be out of date",
                    ", here and in Finder. Changes from other devices won’t arrive, and folders not downloaded "
                    + "to this Mac won’t open, until it runs.")
        case .notResponding:
            return ("\(sourceName) isn’t responding, so these files may be out of date",
                    ", here and in Finder. A folder not downloaded to this Mac didn’t open within 5 seconds; "
                    + "it shows as unexplored until it answers.")
        case .iCloudOff:
            return ("iCloud is signed out, or iCloud Drive is off, so these files may be out of date",
                    ", here and in Finder. Changes from other devices won’t arrive until it’s back on.")
        case .notUploading(let paths, let since):
            let files = paths.count == 1 ? "a file" : "\(paths.count) files"
            return ("\(sourceName) hasn’t uploaded \(files) SyncCloud changed here",
                    " for \(CloudAppNotice.duration(now.timeIntervalSince(since))), so your other devices don’t have "
                    + "\(paths.count == 1 ? "it" : "them") yet.")
        }
    }

    /// The line itself: what is wrong, then what it means. Short enough for one line in most panes;
    /// the tail truncates in a narrow one, and the link at the end never does.
    static func line(for problem: CloudAppProblem, sourceName: String, now: Date) -> (lead: String, rest: String) {
        switch problem {
        case .notRunning(let app):
            return ("\(app.name) isn’t running", " · files may be out of date")
        case .notResponding:
            return ("\(sourceName) isn’t responding", " · files may be out of date")
        case .iCloudOff:
            return ("iCloud is signed out or iCloud Drive is off", " · files may be out of date")
        case .notUploading(let paths, let since):
            let files = paths.count == 1 ? "a file" : "\(paths.count) files"
            return ("\(sourceName) hasn’t uploaded \(files) for \(CloudAppNotice.duration(now.timeIntervalSince(since)))",
                    " · your other devices don’t have \(paths.count == 1 ? "it" : "them") yet")
        }
    }

    /// The line's one link, or none.
    static func action(for problem: CloudAppProblem, canOpen: (CloudApp) -> Bool) -> CloudAppNotice.Action? {
        switch problem {
        case .notRunning(let app): return canOpen(app) ? .open(app) : nil
        case .notResponding: return nil
        case .iCloudOff: return .openICloudSettings
        case .notUploading(let paths, _): return .show(paths)
        }
    }

    public var body: some View {
        let full = Self.sentence(for: problem, sourceName: sourceName, now: now)
        let short = Self.line(for: problem, sourceName: sourceName, now: now)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(.system(size: 11))
                .foregroundStyle(SemanticColor.warning)
                .accessibilityHidden(true)
            (Text(short.lead).fontWeight(.semibold) + Text(short.rest))
                .scaledFont(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                // The line is the short form; the tooltip and VoiceOver get the whole sentence.
                .help(full.lead + full.rest)
                .accessibilityLabel("Warning: " + full.lead + full.rest)
            Spacer(minLength: 8)
            if let action = Self.action(for: problem, canOpen: canOpen) {
                Button(action.title) { onAction(action) }
                    .buttonStyle(.link)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SemanticColor.warning.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}

/// **The amber dot and its words** beside a source in the sidebar — "not running", "not
/// responding". Drawn only when a problem is known; there is no green.
public struct CloudAppStatusDot: View {
    let problem: CloudAppProblem

    public init(_ problem: CloudAppProblem) {
        self.problem = problem
    }

    public var body: some View {
        // The dot never shrinks; the words truncate first. A caller in a narrow row gives this a low
        // layout priority, so the source's own name — which says which source is in trouble —
        // keeps its room.
        HStack(spacing: 4) {
            dot
            Text(problem.shortLabel)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help("\(problem.shortLabel.prefix(1).uppercased() + problem.shortLabel.dropFirst()) — \(problem.consequence)")
    }

    private var dot: some View {
        Circle()
            .fill(SemanticColor.warning)
            .frame(width: 6, height: 6)
            .fixedSize()
    }

    /// The dot for a menu item. A menu draws its images as templates unless told otherwise, which
    /// would turn amber into the menu's ink — so it is an image that is not one.
    @MainActor public static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}

/// **Activity ▸ Now's rows for cloud apps that aren't syncing** — information, with no
/// notification. Dismiss hides a row until what it says changes.
struct CloudAppNoticeRows: View {
    @ObservedObject var monitor: CloudAppMonitor

    var body: some View {
        if !monitor.notices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cloud Apps")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(monitor.notices.enumerated()), id: \.element.id) { index, notice in
                    if index > 0 { Divider().padding(.leading, 12) }
                    row(notice)
                }
            }
        }
    }

    private func row(_ notice: CloudAppNotice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(SemanticColor.warning)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice.detail)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // In a row while they fit; three Open buttons and Dismiss do not fit the popover's
                // width, so they stack there rather than truncate.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { buttons(notice) }
                    VStack(alignment: .leading, spacing: 4) { buttons(notice) }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func buttons(_ notice: CloudAppNotice) -> some View {
        ForEach(notice.actions.filter(isOffered), id: \.title) { action in
            Button(action.title) { monitor.perform(action) }
                .fixedSize()
        }
        Button("Dismiss") { monitor.dismiss(notice) }
            .fixedSize()
            .help("Hide this until it changes")
    }

    private func isOffered(_ action: CloudAppNotice.Action) -> Bool {
        if case .open(let app) = action { return monitor.canOpen(app) }
        return true
    }
}
