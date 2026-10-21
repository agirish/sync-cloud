import SwiftUI
import Design
import Sync

/// **One sheet for every file in the batch** — its options once, then its progress: "File 2 of 5 ·
/// page 40 of 112" over a row per file. Mockup 14.
struct EditorPDFBatchSheet: View {
    @ObservedObject var batch: EditorPDFBatch
    @State private var byTarget = false
    @State private var quality = EditorPDFCompression.strengths[1].quality
    @State private var typedMegabytes = "2"
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).scaledFont(.system(size: 13, weight: .semibold))
            if batch.isRunning || isRotate {
                progressRows
            } else {
                options
            }
            Text("Each copy is written next to its original. The originals aren’t changed.")
                .scaledFont(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    if batch.isRunning { batch.cancel() } else { batch.showsSheet = false }
                }
                .keyboardShortcut(.cancelAction)
                // Its words keep the raw accent — see `EditorPDFToolSheetFrame`.
                .tint((LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor)
                if !isRotate {
                    Button(actionTitle, action: go)
                        .keyboardShortcut(.defaultAction)
                        .disabled(batch.isRunning || !canRun)
                }
            }
        }
    }

    private var isRotate: Bool {
        if case .rotate = batch.kind { return true }
        return false
    }

    private var title: String {
        let files = "\(batch.count) files"
        switch batch.kind {
        case .rotate(let turns): return "Rotate \(files) \(EditorPDFCopyName.degrees(turns))"
        case .compress: return "Compress \(files)"
        case .cleanMetadata: return "Clean Metadata of \(files)"
        }
    }

    private var actionTitle: String {
        switch batch.kind {
        case .rotate: return "Rotate"
        case .compress: return "Save \(batch.count) Compressed Copies"
        case .cleanMetadata: return "Save \(batch.count) Cleaned Copies"
        }
    }

    private var canRun: Bool {
        if case .compress = batch.kind, byTarget { return EditorPDFCompression.megabytes(typedMegabytes) != nil }
        return true
    }

    @ViewBuilder
    private var options: some View {
        switch batch.kind {
        case .compress:
            VStack(alignment: .leading, spacing: 10) {
                EditorPDFCompressControls(byTarget: $byTarget, quality: $quality,
                                          typedMegabytes: $typedMegabytes, perFile: true)
                Text("Every page is redrawn as an image, so text in the copies can’t be selected. "
                     + "Files that wouldn’t get noticeably smaller are skipped.")
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .cleanMetadata:
            Text("Each copy has its title, author, subject, keywords and creator cleared. Producer and the "
                 + "created and modified dates are replaced with the system’s own. Password-protected "
                 + "files are skipped.")
                .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .rotate:
            EmptyView()
        }
    }

    private var progressRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = batch.progress {
                ProgressView(value: progress.fraction)
                Text(progress.text)
                    .scaledFont(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(EditorPDFFind.waitingCaption)
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(batch.files) { file in
                        HStack {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Self.statusText(file.status, progress: batch.progress))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .scaledFont(.system(size: 11))
                        .fontWeight(file.status == .running ? .semibold : .regular)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    static func statusText(_ status: EditorPDFBatch.Status, progress: EditorPDFBatch.Progress?) -> String {
        switch status {
        case .waiting: return "waiting"
        case .running:
            if let page = progress?.page, let pages = progress?.pages { return "page \(page) of \(pages)" }
            return "working…"
        case .wrote(_, let sizes): return sizes ?? "done"
        case .skipped(let skip): return skip == .cancelled ? "not done" : "skipped, \(skip.reason)"
        case .failed: return "failed"
        }
    }

    private func go() {
        let tool: EditorPDFBatchTool
        switch batch.kind {
        case .rotate(let turns): tool = .rotate(quarterTurns: turns)
        case .compress:
            if byTarget {
                guard let megabytes = EditorPDFCompression.megabytes(typedMegabytes) else { return }
                tool = .compress(.target(bytes: EditorPDFCompression.bytes(megabytes: megabytes)))
            } else {
                tool = .compress(.quality(quality))
            }
        case .cleanMetadata: tool = .cleanMetadata
        }
        Task { await batch.run(tool) }
    }
}
