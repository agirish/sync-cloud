import AppKit
import Foundation
import SwiftUI
import Sync
@testable import FileExplorer

extension AutomationDryRunRow {
    /// A row the filing walkthrough would file: `/inbox/<name>` into `/root/Docs`.
    static func walkFixture(_ name: String) -> AutomationDryRunRow {
        AutomationDryRunRow(id: "/inbox/\(name)", fileName: name, ruleID: UUID(), ruleName: "Rule",
                            verdict: .wouldFile(destination: "Docs"),
                            destinationDir: URL(fileURLWithPath: "/root/Docs"), destinationLabel: "Docs",
                            destinationAnchor: URL(fileURLWithPath: "/root"))
    }
}

/// An Organize lens (or anything else) mounted for pixel reads: `size` points over `background`, in
/// an sRGB window of `appearance` with the matching colour scheme, laid out `passes` times.
///
/// The window and its background are not decoration: without them the content composites against
/// the borderless window's own buffer and every comparison reads as zero difference. Two passes
/// where `.onGeometryChange` writes state after the first (the rail's `railStyle`), or one layout
/// renders only the initial answer.
@MainActor
enum ReviewLensHost {
    static func mount(_ view: some View, size: CGSize, appearance: NSAppearance.Name = .aqua,
                      background: Color = Color(nsColor: .windowBackgroundColor),
                      passes: Int = 1) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height)
            .background(background)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = HostedView.window(host.frame)
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        for _ in 0..<passes { host.layoutSubtreeIfNeeded() }
        return (host, window)
    }
}
