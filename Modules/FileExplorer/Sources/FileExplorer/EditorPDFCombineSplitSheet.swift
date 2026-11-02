import SwiftUI
import Design
import Sync

/// **Combine's and Split's one sheet** (TE294): Combine's files in order, each with ↑ and ↓ —
/// buttons rather than a drag, which a SwiftUI list wedged on in the 11-01 spike — and the new
/// file's name; Split's "Start new files at pages" and the parts it makes. The batch sheet's frame
/// and buttons (``EditorPDFBatchSheet``).
struct EditorPDFCombineSplitSheet: View {
    @ObservedObject var run: EditorPDFCombineSplit
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// For the caption's readable red.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).scaledFont(.system(size: 13, weight: .semibold))
            switch run.job {
            case .combine: combine
            case .split: split
            }
            Text("The originals aren’t changed.")
                .scaledFont(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { run.showsSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonWordsTint((LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor)
                Button(actionTitle) { Task { await run.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || run.isRunning)
                    .accentedProminent()
            }
        }
    }

    private var title: String {
        switch run.job {
        case .combine(let paths): return "Combine \(paths.count.formatted()) PDFs"
        case .split(let path): return "Split “\((path as NSString).lastPathComponent)”"
        }
    }

    private var actionTitle: String {
        switch run.job {
        case .combine: return "Combine"
        case .split:
            if case .success(let parts) = parts { return "Split into \(parts.count) Files" }
            return "Split"
        }
    }

    /// Why the button is greyed, said where the field is.
    private var problem: String? {
        switch run.job {
        case .combine:
            if case .failure(let problem) = EditorPDFCombineSplit.fileName(run.name) { return problem.sentence }
            return nil
        case .split:
            if case .failure(let problem) = parts { return problem.sentence }
            return nil
        }
    }

    private var parts: Result<[[Int]], EditorPDFCombineSplit.SplitProblem> {
        EditorPDFCombineSplit.parts(run.splitAt, pageCount: run.pageCount)
    }

    // MARK: Combine

    private var combine: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(run.order.enumerated()), id: \.element) { index, path in
                        combineRow(index, path)
                    }
                }
            }
            .frame(maxHeight: 200)
            HStack(spacing: 8) {
                Text("Name").scaledFont(.system(size: 11))
                TextField("Combined.pdf", text: $run.name)
                    .textFieldStyle(.roundedBorder)
            }
            caption(problem, isError: problem != nil,
                    otherwise: "Saved in “\(firstFolder)”, where the first file is. \(EditorPDFCombineSplit.combineNote)")
        }
    }

    private func combineRow(_ index: Int, _ path: String) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                // Two "Receipt.pdf" in two places must never look alike.
                if run.rowsShowFolders {
                    Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        .scaledFont(.system(size: 10))
                }
            }
            Spacer(minLength: 8)
            Button { run.move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move up")
                .accessibilityLabel("Move \((path as NSString).lastPathComponent) up")
            Button { run.move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == run.order.count - 1)
                .help("Move down")
                .accessibilityLabel("Move \((path as NSString).lastPathComponent) down")
        }
        .buttonStyle(.borderless)
        .scaledFont(.system(size: 11))
    }

    private var firstFolder: String {
        ((run.order.first ?? "") as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? ""
    }

    // MARK: Split

    private var split: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(run.pageCount) pages").scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Start new files at pages").scaledFont(.system(size: 11))
                TextField("4, 9", text: $run.splitAt)
                    .textFieldStyle(.roundedBorder)
            }
            if case .success(let parts) = parts {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Text(EditorPDFCopyName.pageList(part))
                            .monospacedDigit().scaledFont(.system(size: 11))
                    }
                }
            }
            caption(problem, isError: problem != nil && !run.splitAt.isEmpty,
                    otherwise: "Each file is saved next to the original, named for its pages.")
            if let note = run.formNote {
                Text(note).scaledFont(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(_ problem: String?, isError: Bool, otherwise: String) -> some View {
        Text(isError ? (problem ?? otherwise) : otherwise)
            .scaledFont(.system(size: 10))
            // The readable red: bare `.red` falls short of 4.5:1 at this size (DS2).
            .foregroundStyle(isError ? AnyShapeStyle(ChromeInk.bodyText(colorScheme, SemanticColor.error))
                                     : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
