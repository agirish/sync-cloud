import Testing
import SwiftUI
import AppKit
import Design
import FileExplorer
import Sync
import Dashboard
@testable import SyncCloud

/// What a brand mark measures when an AppKit-backed control draws it. A resizable image inside a
/// menu label balloons to its native size, drawing the source's mark across the pane and pushing
/// the nav bar off the row. **The brand assets live in `MacApp/Assets.xcassets`, which no SPM test
/// target can see**: there `NSImage(named:)` is nil and `ProviderLogo` falls back to an SF Symbol,
/// sized by font, so package snapshots measure a stand-in. So these live in the app target and
/// measure `fittingSize`: the failure is a layout one, the label's ideal width, and needs no window
/// or display.
@MainActor
struct MenuLabelMarkTests {

    /// Without this the whole file is a statement about `folder.fill`. First, and loud.
    @Test func theBrandAssetsAreReachableFromThisTarget() {
        for name in ["googledrive", "icloud", "dropbox", "onedrive"] {
            #expect(NSImage(named: name) != nil,
                    "\(name) is not in this target's catalog — every measurement here would be of an SF Symbol")
        }
    }

    private static let sources = [
        CloudProvider(id: "gd", displayName: "Google Drive (EMP)", imageName: "googledrive",
                      rootPath: "/tmp/gd", openAt: "My Drive", type: .googleDrive),
        CloudProvider(id: "ic", displayName: "iCloud", imageName: "icloud",
                      rootPath: "/tmp/ic", type: .iCloud)
    ]

    /// The width SwiftUI would ask for, with nothing constraining it. A wrapper that pins a frame
    /// reports the frame back and measures nothing.
    private func idealWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    private func menu<L: View>(@ViewBuilder label: () -> L) -> some View {
        ProviderMenu(providers: Self.sources, currentId: "gd",
                     onSelect: { _ in }, onManage: {}, onChooseFolder: nil, label: label)
    }

    /// The mechanism, kept alive so the fix can't quietly stop mattering. These assets are 512pt on
    /// the long edge, and a resizable image in an AppKit-drawn label draws at that whatever its
    /// frame. Asserted as "at least ten times what it asked for", not an exact number, so
    /// re-exporting the artwork doesn't fail it.
    @Test func aResizableMarkInsideAMenuLabelIgnoresItsFrame() {
        let asked: CGFloat = 15
        let width = idealWidth(menu { ProviderLogo("googledrive", size: asked) })
        #expect(width > asked * 10,
                "a resizable mark in a menu label measured \(width) for a \(asked)pt request — if this is now small, `inAppKitLabel` is no longer buying anything and the tests below have stopped discriminating")
    }

    /// The fix: the same mark at the same size, built at a fixed intrinsic size. The bound is the
    /// mark plus the menu's own chrome, so it isn't the size asked for exactly.
    @Test func aPresizedMarkInsideAMenuLabelIsTheSizeItWasAsked() {
        for name in ["googledrive", "icloud", "dropbox", "onedrive"] {
            let width = idealWidth(menu { ProviderLogo(name, size: 15, inAppKitLabel: true) })
            #expect(width < 45, "\(name) measured \(width) in a menu label — it is drawing at its native size")
        }
    }

    /// The catalog's own image is not resized. `NSImage(named:)` hands back a shared instance, and
    /// setting `size` on it would shrink the mark everywhere else (Settings, the single-source rail,
    /// the Browse sidebar).
    @Test func presizingAMarkLeavesTheCatalogsCopyAlone() throws {
        let before = try #require(NSImage(named: "googledrive")).size
        _ = idealWidth(menu { ProviderLogo("googledrive", size: 15, inAppKitLabel: true) })
        let after = try #require(NSImage(named: "googledrive")).size
        #expect(before == after, "the catalog's shared image went from \(before) to \(after)")
    }

    /// End to end: the header the app builds doesn't blow up. Built through `PaneHeader`, which
    /// assembles the picker from a `CloudProvider`, so a header that stopped passing one can't stay
    /// green. The bound is ideal width, not "fits a 250pt pane": a middle-truncating breadcrumb
    /// wants about 260 here, while the mark at its native 512 pushes past 700. Turning
    /// `inAppKitLabel` off in `PaneBreadcrumb.rootCrumb` must fail it. A narrow-pane render can't see
    /// this (the row compresses instead of overflowing); whether the bar fits its pane is
    /// `PaneBarLadderTests`.
    @Test func theHeaderCarryingASourcePickerDoesNotBlowUpTheRow() {
        let width = idealWidth(Self.header(relativePath: "Taxes/2026"))
        #expect(width < 400,
                "the pane header wants \(width)pt of ideal width — the source's mark is drawing at its native size")
    }

    @MainActor
    private static func header(relativePath: String, provider: CloudProvider? = sources[0]) -> some View {
        PaneHeader(
            title: "Left",
            provider: provider,
            rootPath: provider?.rootPath ?? "/tmp/none",
            relativePath: relativePath,
            canGoBack: true,
            canGoForward: false,
            onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in },
            providers: sources,
            onSelectProvider: { _ in },
            onManageProviders: {},
            onChooseFolder: nil,
            sortOption: .constant(.name),
            showHiddenFiles: .constant(false)
        )
    }
}
