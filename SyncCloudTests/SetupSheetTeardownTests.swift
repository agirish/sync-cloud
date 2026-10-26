import AppKit
import Foundation
import Settings
import SwiftUI
import Testing
@testable import SyncCloud

/// **Taking the sheet down keeps the open screen's answers, whatever takes it down** (ST4).
///
/// The card's own ways out — Esc, ✕, a click outside, Not Now — commit through `close()`. But
/// ContentView's overlays are one if/else, and Settings (⌘,), Help (⌘?) and a destination pick
/// rank above setup: opening one destroys `SetupSheet` and its `@StateObject` model without a
/// `close()`, as closing the window does, and setup reopened on a fresh model with the name typed
/// on You gone.
///
/// Hosted for real, because the fix is a view's `onDisappear` and nothing else can see it. The
/// draft is asked of disk, in a scratch folder — never the real `setup-draft.json` — because the
/// draft is what the next open reads. Quitting is heard through `willTerminateNotification`,
/// which this test host must not post (the host IS SyncCloud.app, and every observer in it would
/// hear it); `SetupFlowTests.theSetupButtonsCallTheRulesTheModelTests` pins that observer by source.
@MainActor
@Suite struct SetupSheetTeardownTests {

    /// Stands in for ContentView's overlay chain: a branch above setup taking its place.
    final class Chain: ObservableObject {
        @Published var showsSetup = true
    }

    struct Host: View {
        @ObservedObject var chain: Chain
        let sheet: SetupSheet
        var body: some View {
            if chain.showsSetup { sheet } else { Color.clear }
        }
    }

    private struct Fixture {
        let model: SetupModel
        let draftURL: URL
        let root: URL
        let chain: Chain
        let window: NSWindow
        let dismissals: Counter
    }

    final class Counter { var count = 0 }

    private func mount(_ tag: String) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-teardown-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let draftURL = root.appendingPathComponent("setup-draft.json")
        let defaults = ScratchDefaults("setup-teardown-\(tag)")
        let settings = SettingsManager(
            autoDiscover: false, userDefaults: ScratchDefaults("setup-teardown-s-\(tag)"),
            cloudStorageLister: { CloudStorageAccounts(folders: [], rootWasReadable: true) },
            pathValidator: { _ in true })
        await settings.discoverProviders()
        let model = SetupModel(settings: settings, peopleStore: nil, syncManager: nil,
                               hasFilingProfile: false, defaults: defaults,
                               startScreen: .you, draftURL: draftURL)
        let dismissals = Counter()
        let sheet = SetupSheet(settings: settings, peopleStore: nil, glassHue: .blue,
                               glassLevel: .frosted, surfaceTint: 0,
                               availableSize: CGSize(width: 1000, height: 700),
                               hasFilingProfile: false, defaults: defaults, draftURL: draftURL,
                               model: model, onOpenSettings: { _ in }, onFinish: {},
                               onDismiss: { dismissals.count += 1 })
        let chain = Chain()
        let host = NSHostingView(rootView: Host(chain: chain, sheet: sheet)
            .frame(width: 1000, height: 700)
            .defaultAppStorage(defaults))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Buried under everything, never parked on his screen (FileExplorer's `BuriedWindow`).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        // Let `onAppear` run — it seeds the name from the account, so the typing comes after.
        try await Task.sleep(for: .milliseconds(200))
        model.firstName = "Maya"
        #expect(SetupDraftStore.read(at: draftURL) == nil, "premise: nothing is written while typing")
        return Fixture(model: model, draftURL: draftURL, root: root, chain: chain, window: window,
                       dismissals: dismissals)
    }

    /// Polls the draft for a bounded time: the teardown lands on a later main-loop turn.
    private func draftOnceWritten(at url: URL) async throws -> SetupDraft? {
        for _ in 0..<300 {
            if let stored = SetupDraftStore.read(at: url) { return stored }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Settings, Help or a destination pick opening over setup.
    @Test(.timeLimit(.minutes(1)))
    func aPanelOpeningOverSetupKeepsTheTypedName() async throws {
        let fixture = try await mount("panel")
        defer {
            fixture.window.orderOut(nil)
            try? FileManager.default.removeItem(at: fixture.root)
        }

        fixture.chain.showsSetup = false

        let stored = try #require(try await draftOnceWritten(at: fixture.draftURL),
                                  "taking the sheet down wrote no draft")
        #expect(stored.yourName == "Maya", "taking the sheet down dropped the name typed on You")
        #expect(fixture.dismissals.count == 0, "premise: this was not the card's own close")
    }

    /// The window closing with setup open.
    ///
    /// **Closed and its content let go, as the app's `WindowGroup` does** — the app outlives the
    /// window, and a Dock click makes a new one. A bare `close()` of a window the test still holds
    /// keeps the hosting view alive, and nothing disappears: measured, no draft in 3 s.
    @Test(.timeLimit(.minutes(1)))
    func closingTheWindowKeepsTheTypedName() async throws {
        let fixture = try await mount("window")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.window.close()
        fixture.window.contentView = nil

        let stored = try #require(try await draftOnceWritten(at: fixture.draftURL),
                                  "closing the window wrote no draft")
        #expect(stored.yourName == "Maya", "closing the window dropped the name typed on You")
        #expect(fixture.dismissals.count == 0, "premise: this was not the card's own close")
    }
}
