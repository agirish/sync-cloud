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

    /// The colors Customize Groups holds, changed from outside the form as a pick would.
    @MainActor final class Colors: ObservableObject {
        @Published var byGroup: [String: VaultCardColor] = [:]
    }

    /// Two rows of wells in a grouped form, as in Customize Groups; each change redraws every row.
    struct WellRows: View {
        @ObservedObject var colors: Colors

        var body: some View {
            Form {
                ForEach(["Travel", "Money"], id: \.self) { group in
                    HStack {
                        VaultColorWell(color: Binding(get: { colors.byGroup[group] }, set: { colors.byGroup[group] = $0 }),
                                       label: "Color of the group \(group)", what: "group \(group)")
                        Text(group)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The popover a well opens stays open while colors are tried, as a card's Color… does,
    /// though every row of the form is drawn again with each change (the 2026-11-25 review). The
    /// colors change from outside, as a pick changes them: clicking a swatch inside the popover,
    /// whose frame makes room for its arrow, found it on this Mac but not on the hosted runner.
    @Test func aWellsSwatchesStayOpenWhileColorsAreTried() async throws {
        let colors = Colors()
        let size = CGSize(width: 360, height: 220)
        let host = NSHostingView(rootView: WellRows(colors: colors).frame(width: size.width, height: size.height))
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
        defer { shown.close() }
        for tint in VaultTint.allCases.prefix(2) {
            colors.byGroup["Travel"] = .tint(tint)
            colors.byGroup["Money"] = .tint(tint)
            try await Task.sleep(for: .milliseconds(300))
            #expect(popover() === shown, "the swatches closed when the rows were drawn again")
        }
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
        let panel = VaultCard(model: rig.model, glassHue: .blue, onClose: {}, onOpenSettings: { _ in },
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
