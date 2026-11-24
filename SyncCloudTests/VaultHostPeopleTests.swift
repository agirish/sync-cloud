import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// The window's ``VaultHost`` hands the model the household from its first frame, so the panel,
/// which draws from `model.people` alone, has it before it ever opens, and follows each change.
@MainActor
@Suite(.serialized) struct VaultHostPeopleTests {
    final class PeopleBox: ObservableObject {
        @Published var people: [Person]
        init(_ people: [Person]) { self.people = people }
    }

    struct Probe: View {
        @ObservedObject var box: PeopleBox
        let model: VaultModel
        var body: some View {
            Color.clear.modifier(VaultHost(isShown: .constant(false), suspended: false, model: model,
                                           people: box.people, onOpened: {}))
        }
    }

    @Test func theHostGivesTheModelItsPeopleBeforeThePanelOpensAndAsTheyChange() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        rig.model.people = []
        let bo = Person(id: "bo", displayName: "Bo"), cy = Person(id: "cy", displayName: "Cy")
        let box = PeopleBox([bo])
        let host = NSHostingView(rootView: Probe(box: box, model: rig.model))
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async throws {
            for _ in 0..<3 {
                window.layoutIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        #expect(rig.model.people == [bo], "the host's first frame hands the model the household")
        box.people = [bo, cy]
        try await settle()
        #expect(rig.model.people == [bo, cy], "a change in People follows")
    }
}
