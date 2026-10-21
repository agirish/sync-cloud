import AppKit
import Combine
import Events
import SwiftUI
import Design
import Sync

/// What the window does around a Save as PDF run — the half that needs the app.
public struct PaneSaveAsPDFHost {
    /// A PDF landed at this path: the panes showing its folder re-read.
    public var didWrite: (String) -> Void
    /// The banner's Open in Edit — the PDF in Edit's reader.
    public var open: (String) -> Void
    /// The banner's Reveal in Browse — the one PDF, or a batch's PDFs.
    public var reveal: ([String]) -> Void
    /// **Where to save when the original's folder cannot be written to** — handed the original and
    /// the name the PDF would have had, answering a path or `nil` for "don't save this one". The app
    /// asks with a save panel (CV4).
    public var chooseDestination: (_ original: String, _ suggestedName: String) -> String?

    public init(didWrite: @escaping (String) -> Void = { _ in },
                open: @escaping (String) -> Void = { _ in },
                reveal: @escaping ([String]) -> Void = { _ in },
                chooseDestination: @escaping (String, String) -> String? = { _, _ in nil }) {
        self.didWrite = didWrite
        self.open = open
        self.reveal = reveal
        self.chooseDestination = chooseDestination
    }
}

/// How a run ended, in the banner's words, with what it offers.
public struct SaveAsPDFBanner: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// One PDF, at this path — Open in Edit and Reveal in Browse.
        case saved(String)
        /// Several PDFs — Reveal in Browse selects them.
        case savedSeveral([String])
        /// Nothing was saved, and nothing went wrong — a run stopped before its first file.
        case note
        case failure
    }
    public let id = UUID()
    public var message: String
    /// A second line: a deck saved as pictures — its text recognised or not — and why each file
    /// that failed did.
    public var detail: String?
    public var kind: Kind

    public static func == (lhs: SaveAsPDFBanner, rhs: SaveAsPDFBanner) -> Bool {
        lhs.message == rhs.message && lhs.detail == rhs.detail && lhs.kind == rhs.kind
    }
}

/// **Save as PDF, run from a pane's row menu or File ▸ Save as PDF** — one window-level owner for
/// the run, its progress and its banner.
///
/// **One file at a time, beside its original, never over anything** (CV4, decision AN): each file
/// is rendered (``SaveAsPDFRender``) and written as `<name>.pdf` in its own folder — `<name> 2.pdf`
/// when that is taken — by ``EditorPDFCopyWriter``, which stages the bytes and moves them in with
/// `RENAME_EXCL`. The original is only ever read. A folder that cannot be written to asks where
/// instead, through the host. Stop ends the run between files; the PDFs already written stay.
///
/// One run at a time: a second request while one is in flight is told so, in the running banner.
@MainActor
public final class PaneSaveAsPDF: ObservableObject {

    public struct Progress: Equatable, Sendable {
        /// Files finished — written, failed or skipped.
        public var done: Int
        public var total: Int
        /// The file being rendered now.
        public var name: String
    }

    @Published public private(set) var progress: Progress?
    @Published public var banner: SaveAsPDFBanner?
    /// Said over the progress when a second request arrives mid-run.
    @Published public private(set) var busyNote: String?
    /// Set by the window before each request.
    public var host = PaneSaveAsPDFHost()
    /// Settings ▸ Text size and the window's accent — what Edit's Print sets a note in.
    public var fontScale: CGFloat = 1
    public var accent: Color = .accentColor

    /// The run's task — kept so a test can await it; nothing in the app does.
    private(set) var work: Task<Void, Never>?
    private var stopRequested = false

    /// A test's to answer: whether a file is still only in the cloud, asked again as its turn comes.
    var isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    /// A test's to answer: whether the original's folder takes a new file.
    var folderIsWritable: (String) -> Bool = { SaveAsPDFName.folderIsWritable(for: $0) }
    /// The reader's paper, read when each file's turn comes.
    var geometry: () -> DocumentPDF.PageGeometry = { .from(NSPrintInfo.shared) }

    public init() {}

    public var isRunning: Bool { progress != nil }

    /// The request a row's menu or File ▸ made, over `paths`. `writer` names the workspace in the log.
    public func start(paths: [String], writer: String) {
        let paths = paths.filter { SaveAsPDFKind.of(path: $0) != nil }
        guard !paths.isEmpty else { return }
        guard !isRunning else {
            busyNote = "Still saving the last files. Try again when they’re done."
            Logger.shared.info("\(writer): Save as PDF refused — a run is still going")
            return
        }
        stopRequested = false
        busyNote = nil
        banner = nil
        progress = Progress(done: 0, total: paths.count, name: (paths[0] as NSString).lastPathComponent)
        work = Task { @MainActor in await run(paths, writer: writer) }
    }

    /// Stop after the file in hand. Its PDF, and every one before it, stays.
    public func stop() {
        stopRequested = true
    }

    private func run(_ paths: [String], writer: String) async {
        // Asked for, and watched in the banner: not work for App Nap to slow when the window is
        // behind another app's.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Saving files as PDF")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var saved: [SaveAsPDFSummary.Saved] = []
        var failed: [SaveAsPDFSummary.Failed] = []
        var stoppedBefore = 0
        for (index, path) in paths.enumerated() {
            if stopRequested {
                stoppedBefore = paths.count - index
                break
            }
            let name = (path as NSString).lastPathComponent
            progress = Progress(done: index, total: paths.count, name: name)
            if let reason = await save(path, writer: writer, into: &saved) {
                failed.append(.init(name: name, reason: reason))
                Logger.shared.info("\(writer) could not save \(name) as PDF — \(reason)")
            }
        }
        progress = nil
        busyNote = nil
        banner = SaveAsPDFSummary.banner(total: paths.count, saved: saved, failed: failed, stoppedBefore: stoppedBefore)
    }

    /// One file: rendered, then written. Answers why it was not saved, or `nil` when it was.
    private func save(_ path: String, writer: String, into saved: inout [SaveAsPDFSummary.Saved]) async -> String? {
        let name = (path as NSString).lastPathComponent
        // Evicted since the menu was built: reading the placeholder would download it, which nobody
        // asked for.
        if isCloudOnly(path) { return "it isn’t downloaded" }
        let wanted = SaveAsPDFName.firstChoice(for: path)
        // Asked before the render, so a cancelled panel costs nothing.
        var chosen: String?
        if !folderIsWritable(path) {
            guard let answer = host.chooseDestination(path, (wanted as NSString).lastPathComponent) else {
                return "its folder can’t be written to"
            }
            chosen = answer
        }
        let settings = SaveAsPDFRender.Settings(geometry: geometry(), fontScale: fontScale, accent: accent)
        let started = Date()
        do {
            let output = try await SaveAsPDFRender.render(path, settings: settings)
            let copy: String
            if let chosen {
                // The panel asked about replacing; this is a save to where the reader said.
                try EditorFileStore.write(output.data, toPath: chosen)
                copy = chosen
            } else {
                copy = try EditorPDFCopyWriter.write(output.data, wanting: wanted)
            }
            saved.append(.init(name: name, copy: copy, pageCount: output.pageCount,
                               picturePages: output.picturePages, isRecognised: output.isRecognised))
            Logger.shared.info("\(writer) saved \(name) as \((copy as NSString).lastPathComponent) — "
                               + "\(output.pageCount) page\(output.pageCount == 1 ? "" : "s")"
                               + (output.isPictures ? ", slides as pictures"
                                  : output.picturePages > 0 ? ", \(output.picturePages) of the slides as pictures" : "")
                               + (output.isRecognised ? ", text recognised" : "")
                               + String(format: ", %.1f s", Date().timeIntervalSince(started)))
            host.didWrite(copy)
            return nil
        } catch let failure as SaveAsPDFFailure {
            return failure.reason
        } catch {
            return error.localizedDescription
        }
    }
}

/// **The banner's words for how a run ended** — pure, so each sentence is pinned by a test.
enum SaveAsPDFSummary {
    struct Saved: Equatable {
        var name: String
        var copy: String
        var pageCount: Int
        /// Slides that were pictures — all of them, some, or none.
        var picturePages: Int
        var isRecognised: Bool

        var isPictures: Bool { pageCount > 0 && picturePages == pageCount }
    }

    struct Failed: Equatable {
        var name: String
        var reason: String
    }

    static func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }

    /// “A”, “A” and “B”, “A”, “B” and “C”, or “A”, “B”, “C” and 2 more.
    static func names(_ names: [String]) -> String {
        list(names.map { "“\($0)”" })
    }

    /// The items as ``names(_:)`` lists them, as they are.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2, 3: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        default: return items.prefix(3).joined(separator: ", ") + " and \(items.count - 3) more"
        }
    }

    static func banner(total: Int, saved: [Saved], failed: [Failed], stoppedBefore: Int) -> SaveAsPDFBanner {
        var detail: [String] = []
        // Read by Vision: searchable, with a misread here and there. A deck only partly pictures
        // says how many of its slides were — the count Abhishek chose on 2026-10-19.
        let recognised = saved.filter { $0.picturePages > 0 && $0.isRecognised }
        if total == 1, let one = recognised.first {
            detail.append(one.isPictures
                ? "Its slides were pictures; their text was recognized so it can be searched, but may have mistakes."
                : "\(one.picturePages) of its \(one.pageCount) slides "
                    + (one.picturePages == 1 ? "was a picture; its" : "were pictures; their")
                    + " text was recognized so it can be searched, but may have mistakes.")
        } else if !recognised.isEmpty {
            let decks = recognised.map { $0.isPictures ? "“\($0.name)”" : "“\($0.name)” (\($0.picturePages) of \($0.pageCount))" }
            detail.append("Slides in \(list(decks)) were pictures; their text was recognized so it can "
                          + "be searched, but may have mistakes.")
        }
        // Not read: no words at all. Said of a deck that was all pictures; a text deck's slide of
        // photos with no words in them is no news.
        let pictures = saved.filter { $0.isPictures && !$0.isRecognised }
        if !pictures.isEmpty {
            detail.append(total == 1
                ? "Its slides were pictures, so their text can’t be selected or searched."
                : "Slides in \(names(pictures.map(\.name))) were pictures, so their text can’t be selected or searched.")
        }
        if total > 1, !failed.isEmpty {
            detail.append(failed.map { "\($0.name): \($0.reason)" }.joined(separator: " · "))
        }
        let note = detail.isEmpty ? nil : detail.joined(separator: " ")

        // One file.
        if total == 1 {
            if let one = saved.first {
                return SaveAsPDFBanner(message: "Saved “\((one.copy as NSString).lastPathComponent)” · \(pages(one.pageCount))",
                                       detail: note, kind: .saved(one.copy))
            }
            if let one = failed.first {
                return SaveAsPDFBanner(message: "Couldn’t save “\(one.name)” as PDF: \(one.reason).",
                                       detail: nil, kind: .failure)
            }
            return SaveAsPDFBanner(message: "Stopped. Nothing was saved.", detail: nil, kind: .note)
        }

        // Several.
        let copies = saved.map(\.copy)
        let kind: SaveAsPDFBanner.Kind = copies.isEmpty ? (failed.isEmpty ? .note : .failure) : .savedSeveral(copies)
        var message: String
        if stoppedBefore > 0 {
            message = "Stopped. Saved \(saved.count) of \(total) as PDF."
        } else if failed.isEmpty {
            message = "Saved \(total) files as PDF."
        } else if saved.isEmpty {
            message = "Couldn’t save any of the \(total) files as PDF."
        } else {
            message = "Saved \(saved.count) of \(total) as PDF."
        }
        if !failed.isEmpty, !saved.isEmpty || stoppedBefore > 0 {
            message += " \(names(failed.map(\.name))) couldn’t be saved."
        }
        return SaveAsPDFBanner(message: message, detail: note, kind: kind)
    }
}

// MARK: - The window's half

/// **Save as PDF's banner at the window's foot** — progress with Stop while it runs, then how it
/// ended, in the strip and card the PDF tools' pane banner uses.
struct PaneSaveAsPDFLayer: View {
    @ObservedObject var model: PaneSaveAsPDF
    let accent: Color

    var body: some View {
        if let progress = model.progress {
            PanePDFToolCard {
                VStack(alignment: .leading, spacing: 0) {
                    EditorPDFToolBannerView.strip(symbol: nil, tint: accent,
                                                  message: Self.progressMessage(progress)) {
                        if progress.total > 1 {
                            Button("Stop") { model.stop() }
                                .controlSize(.small)
                                .help("Stop after this file — the PDFs already saved stay")
                        }
                    }
                    if progress.total > 1 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                            .progressViewStyle(.linear)
                            .tint(accent)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                    if let note = model.busyNote {
                        Self.detailLine(note)
                    }
                }
            }
        } else if let banner = model.banner {
            PanePDFToolCard {
                VStack(alignment: .leading, spacing: 0) {
                    EditorPDFToolBannerView.strip(symbol: Self.symbol(banner.kind),
                                                  tint: banner.kind == .failure ? .red : accent,
                                                  message: banner.message) {
                        switch banner.kind {
                        // The PDF tools' banner's order (``EditorPDFToolBannerView``).
                        case .saved(let path):
                            Button("Open in Edit") { model.host.open(path) }
                                .controlSize(.small)
                                .help("Open the PDF in Edit")
                            Button("Reveal in Browse") { model.host.reveal([path]) }
                                .controlSize(.small)
                                .help("Show the PDF in Browse")
                        case .savedSeveral(let paths):
                            Button("Reveal in Browse") { model.host.reveal(paths) }
                                .controlSize(.small)
                                .help("Show the PDFs in Browse")
                        case .note, .failure:
                            EmptyView()
                        }
                        Button {
                            model.banner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .scaledFont(.system(size: 9, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
                        .accessibilityLabel("Dismiss")
                        .help("Dismiss")
                    }
                    if let detail = banner.detail {
                        Self.detailLine(detail)
                    }
                }
            }
        }
    }

    static func progressMessage(_ progress: PaneSaveAsPDF.Progress) -> String {
        progress.total == 1
            ? "Saving “\(progress.name)” as PDF…"
            : "Saving \(progress.total) files as PDF · \(progress.done + 1) of \(progress.total)"
    }

    /// The PDF tools' banner's icons, so the two cannot drift.
    static func symbol(_ kind: SaveAsPDFBanner.Kind) -> String {
        switch kind {
        case .saved(let path): return EditorPDFToolBannerView.symbol(.wrote(path))
        case .savedSeveral(let paths): return EditorPDFToolBannerView.symbol(.wroteSeveral(paths))
        case .note: return EditorPDFToolBannerView.symbol(.note)
        case .failure: return EditorPDFToolBannerView.symbol(.failure)
        }
    }

    static func detailLine(_ text: String) -> some View {
        Text(text)
            .scaledFont(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// **The row menu's Save as PDF item** — one file or a batch, under the offer's own title.
struct SaveAsPDFMenuItem: View {
    let offer: SaveAsPDFOffer
    let delegate: FileActionDelegate

    var body: some View {
        Button(action: { delegate.handleSaveAsPDF(paths: offer.paths) }) {
            Label(offer.title, systemImage: SaveAsPDFMenuItem.glyph)
        }
    }

    /// A page with a downward arrow — the mockup's glyph.
    static let glyph = "arrow.down.doc"
}
