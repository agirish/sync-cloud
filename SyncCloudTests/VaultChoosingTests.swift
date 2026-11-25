import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// VT75 (owner): one way to choose a color, swatches, wherever a color is chosen; and every
/// layout's empty state the same. Every ID here is made up.
@MainActor
@Suite struct VaultChoosingTests {
    // MARK: The color well

    static let wellSize = CGSize(width: 80, height: 32)

    static func well(_ color: VaultCardColor?, follows: VaultCardColor? = nil) -> some View {
        VaultColorWell(color: .constant(color), follows: follows, label: "Color of Passports", what: "Passports card")
            .frame(width: wellSize.width, height: wellSize.height)
            .background(Color.white)
    }

    @Test func aWellSaysItsColorOrThatItFollowsItsGroup() {
        #expect(VaultColorWell(color: .constant(.tint(.plum)), follows: .tint(.rose), label: "Color of Passports", what: "Passports card").value == "Plum")
        #expect(VaultColorWell(color: .constant(nil), follows: .tint(.rose), label: "Color of Passports", what: "Passports card").value
                == "Same as Group (Rose)")
        #expect(VaultColorWell(color: .constant(.plain), follows: .tint(.rose), label: "Color of Passports", what: "Passports card").value == "No Color")
        // A group's own well has no group to follow.
        #expect(VaultColorWell(color: .constant(.tint(.teal)), label: "Color of the group Travel", what: "group Travel").value == "Teal")
    }

    @Test func aWellIsDrawnInTheColorTheCardIsDrawnIn() throws {
        let rose = VaultCardColorsTests.shade(.rose), plum = VaultCardColorsTests.shade(.plum)
        let follows = try renderInSRGBWindow(Self.well(nil, follows: .tint(.rose)), size: Self.wellSize, scheme: .light)
        #expect(try pixels(near: rose, in: follows) > 20, "a card following its group shows the group's rose")
        let own = try renderInSRGBWindow(Self.well(.tint(.plum), follows: .tint(.rose)), size: Self.wellSize, scheme: .light)
        #expect(try pixels(near: plum, in: own) > 20, "its own plum")
        #expect(try pixels(near: rose, in: own) == 0, "and not the group's")
        let none = try renderInSRGBWindow(Self.well(.plain, follows: .tint(.rose)), size: Self.wellSize, scheme: .light)
        for tint in VaultTint.allCases {
            #expect(try pixels(near: VaultCardColorsTests.shade(tint), in: none) == 0, "no \(tint) for No Color")
        }
    }

    /// Two rows of wells in a grouped form, as in Customize Groups; each pick redraws every row.
    struct WellRows: View {
        @State var colors: [String: VaultCardColor] = [:]
        let picked: (VaultCardColor?) -> Void

        var body: some View {
            Form {
                ForEach(["Travel", "Money"], id: \.self) { group in
                    HStack {
                        VaultColorWell(color: Binding(get: { colors[group] }, set: { colors[group] = $0; picked($0) }),
                                       label: "Color of the group \(group)", what: "group \(group)")
                        Text(group)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The popover a well opens stays open while colors are tried, as a card's Color… does,
    /// though every row of the form is drawn again with each pick (the 2026-11-25 review).
    @Test func aWellsSwatchesStayOpenWhileColorsAreTried() async throws {
        var picks: [VaultCardColor?] = []
        let size = CGSize(width: 360, height: 220)
        let host = NSHostingView(rootView: WellRows { picks.append($0) }.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        host.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        // This window's own popover: another suite's could be open meanwhile.
        func popover() -> NSWindow? {
            (window.childWindows ?? []).first { $0.isVisible && $0.className.contains("Popover") }
        }
        // The first row's well, found by clicking down its left edge.
        var opened: NSWindow?
        for y in stride(from: 10.0, through: size.height - 10, by: 4) {
            click(NSPoint(x: 44, y: size.height - y), in: window)
            try await Task.sleep(for: .milliseconds(20))
            if let found = popover() { opened = found; break }
        }
        let shown = try #require(opened, "no well opened its swatches")
        // Closed, not hidden: an open popover floats above every window, and keeps its views.
        defer { shown.close() }
        func hosting(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("HostingView") { return view }
            return view.subviews.lazy.compactMap(hosting).first
        }
        let content = try #require(shown.contentView.flatMap(hosting))
        // The first swatch, found by clicking across and down: the popover's frame takes room for
        // its arrow, so where the swatches start is not known exactly.
        var spot: NSPoint?
        scan: for y in stride(from: 2.0, through: content.bounds.height - 2, by: 4) {
            for x in stride(from: 4.0, through: 80, by: 6) {
                let point = NSPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y)
                click(content.convert(point, to: nil), in: shown)
                try await Task.sleep(for: .milliseconds(15))
                if !picks.isEmpty { spot = point; break scan }
            }
        }
        let first = try #require(spot, "no swatch answered")
        try await Task.sleep(for: .milliseconds(300))
        #expect(popover() === shown, "the swatches closed after one pick")
        let next = NSPoint(x: first.x + VaultSwatches.swatch + VaultSwatches.gap, y: first.y)
        click(content.convert(next, to: nil), in: shown)
        await waitUntil("the second swatch answered") { picks.count == 2 }
        #expect(picks == [.tint(VaultTint.allCases[0]), .tint(VaultTint.allCases[1])])
        // Closed, not only hidden: an open popover floats above every window and keeps its views.
        shown.performClose(nil)
        await waitUntil("the swatches closed") { popover() == nil }
    }

    // MARK: Every layout's empty state

    /// Each layout, its tab holding IDs that the choices hide every one of, offers the way back,
    /// Show Everything: List said only "Nothing here" (VT75). SwiftUI builds no accessibility tree
    /// in a test, so the button is found by clicking down the middle of the IDs' column.
    @Test(arguments: [VaultLayout.cards, .list, .people])
    func everyLayoutOffersTheWayBackWhenTheChoicesHideEveryID(_ layout: VaultLayout) async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        rig.model.layout = layout
        // The household's passports: there are none.
        rig.model.personFilter = .household
        rig.model.kindFilter = rig.model.groups.group(of: .passport)
        try #require(rig.model.count(in: rig.model.tab) == 0, "every ID hidden")
        let size = VaultPanelRenderTests.size
        let panel = VaultCard(model: rig.model, glassHue: .blue, onClose: {}, onOpenSettings: {},
                              onQuickLook: { _ in }, onReveal: { _ in }, onAddPerson: { _, _ in nil },
                              quickLookPath: nil, onCloseQuickLook: {})
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .defaultAppStorage(rig.defaults)
        let host = NSHostingView(rootView: panel)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Beneath every other window, so nothing shows on screen (VT97).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let column = (size.width - VaultCardSize.detailWidth) / 2
        let found = await clickDown(window, host, x: column, limit: 400) {
            rig.model.personFilter == .everyone && rig.model.kindFilter == nil
        }
        #expect(found != nil, "\(layout): no Show Everything")
    }
}
