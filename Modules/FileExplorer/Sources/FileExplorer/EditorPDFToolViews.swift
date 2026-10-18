import AppKit
import SwiftUI
import PDFToolkitCore
import Design
import Sync

/// **The header's Tools menu** — beside the fit bar, for a PDF that is open or locked. Every item
/// writes a new copy next to the original; the open file stays as it is, and stays read-only.
///
/// It also presents the tools' sheets, whichever surface asked for one: the Pages tab's menu sets
/// ``EditorPDFTools/sheet`` too, and this is the one view that is always mounted while a PDF is.
struct EditorPDFToolsMenu: View {
    @ObservedObject var tools: EditorPDFTools
    let accent: Color

    var body: some View {
        Menu {
            EditorPDFToolsMenuItems(tools: tools)
        } label: {
            Group {
                if tools.running != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                        .scaledFont(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("PDF tools — each writes a new copy and leaves this file as it is")
        .accessibilityLabel("PDF Tools")
        .sheet(item: $tools.sheet) { sheet in
            EditorPDFToolSheetView(tools: tools, sheet: sheet, accent: accent)
        }
    }
}

/// The menu's items, a view of their own so a test can host them.
struct EditorPDFToolsMenuItems: View {
    @ObservedObject var tools: EditorPDFTools

    var body: some View {
        if let reason = tools.disabledReason {
            Text(reason)
            Divider()
        }
        let all = Array(0..<tools.pageCount)
        Group {
            Menu("Rotate All Pages") {
                Button("Rotate Left") { run(.rotate(pages: all, quarterTurns: -1)) }
                Button("Rotate Right") { run(.rotate(pages: all, quarterTurns: 1)) }
                Button("Rotate 180°") { run(.rotate(pages: all, quarterTurns: 2)) }
            }
            Button("Extract Pages…") {
                tools.sheet = .pages(.extract, prefill: EditorPDFPageMenu.rangeText(tools.order.filter(tools.selection.pages.contains)))
            }
            Divider()
            Button("Compress…") { tools.sheet = .compress }
        }
        .disabled(!tools.offersPageTools || tools.running != nil)
        Button("Clean Metadata…") { tools.sheet = .metadata }
            .disabled(!tools.offersMetadata || tools.running != nil)
        Divider()
        if tools.offersRemovePassword {
            Button("Remove Password…") { tools.sheet = .removePassword }
                .disabled(tools.running != nil)
        } else {
            Button("Protect with Password…") { tools.sheet = .protect }
                .disabled(!tools.offersProtect || tools.running != nil)
        }
        if tools.encryption == .restrictedOnly {
            Text(EditorPDFTools.metadataEncryptedReason)
        }
    }

    private func run(_ tool: EditorPDFTool) {
        Task { await tools.run(tool) }
    }
}

/// **What the last run said**, across the top of the PDF card: the copy's name with Open and Reveal
/// in Browse, or why nothing was written.
struct EditorPDFToolBannerView: View {
    @ObservedObject var tools: EditorPDFTools
    let accent: Color

    var body: some View {
        if let banner = tools.banner {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(banner.kind))
                    .foregroundStyle(banner.kind == .failure ? AnyShapeStyle(.red) : AnyShapeStyle(accent))
                Text(banner.message)
                    .scaledFont(.system(size: 11))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if case .wrote(let path) = banner.kind {
                    Button("Open") { tools.host.open(path) }
                    Button("Reveal in Browse") { tools.host.reveal(path) }
                }
                Button {
                    tools.banner = nil
                } label: {
                    Image(systemName: "xmark").scaledFont(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
        }
    }

    static func symbol(_ kind: EditorPDFToolBanner.Kind) -> String {
        switch kind {
        case .wrote: return "checkmark.circle.fill"
        case .note: return "info.circle"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }
}
