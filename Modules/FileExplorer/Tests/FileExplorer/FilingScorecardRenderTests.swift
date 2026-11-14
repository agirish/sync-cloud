import AppKit
import SwiftUI
import Testing
@testable import FileExplorer
@testable import Sync

/// TE341: the scorecard's line and Details sheet, rendered and read back.
@Suite(.serialized) @MainActor struct FilingScorecardRenderTests {
    static let root = "/R"
    static let now = Date()

    static func record(_ verdict: FilingScorecard.Verdict, confidence: FilingConfidence = .high,
                       offered: String = "School/Divit", landed: String = "School/Divit", name: String,
                       daysAgo: Double = 1) -> FilingScorecard.Record {
        FilingScorecard.Record(at: now.addingTimeInterval(-daysAgo * 86_400), picker: .mac, confidence: confidence,
                               evidence: .survey, offered: root + "/" + offered, landed: root + "/" + landed,
                               file: root + "/" + landed + "/" + name, root: root, verdict: verdict,
                               change: verdict == .changed ? .other : nil)
    }

    static func store(_ records: [FilingScorecard.Record]) -> FilingScorecardStore {
        let store = FilingScorecardStore(fileURL: nil)
        store.append(records)
        return store
    }

    static func rendered(_ view: some View, _ size: CGSize) throws -> NSBitmapImageRep {
        try #require(PixelDiff.render(view.frame(width: size.width, height: size.height)
                                        .background(Color(nsColor: .windowBackgroundColor))
                                        .environment(\.colorScheme, .light), size: size))
    }

    static func line(_ store: FilingScorecardStore) throws -> NSBitmapImageRep {
        try rendered(FilingScorecardLine(store: store, accent: .blue, onDetails: {}, onHide: {}),
                     CGSize(width: 520, height: 32))
    }

    @Test(.machinePinned(.pixelSampling)) func theLineDrawsItsCount() throws {
        let one = try Self.line(Self.store([Self.record(.kept, name: "a.pdf"), Self.record(.changed, name: "b.pdf")]))
        let two = try Self.line(Self.store([Self.record(.kept, name: "a.pdf"), Self.record(.kept, name: "b.pdf")]))
        #expect(PixelDiff.differingPixels(one, two, tolerance: 0.05) > 0, "1 of 2 and 2 of 2 must not look the same")
        let none = try Self.line(Self.store([]))
        #expect(PixelDiff.differingPixels(one, none, tolerance: 0.05) > 0)
    }

    @Test(.machinePinned(.pixelSampling)) func aBarDrawsItsSplitAndTheReplayTick() throws {
        func bar(_ t: FilingScorecard.Tally) throws -> NSBitmapImageRep {
            try Self.rendered(FilingScorecardBar(tally: t, deeper: .blue).padding(.vertical, 8), CGSize(width: 200, height: 25))
        }
        let kept = try bar(FilingScorecard.Tally(label: "High", kept: 4))
        let changed = try bar(FilingScorecard.Tally(label: "High", changed: 4))
        let ticked = try bar(FilingScorecard.Tally(label: "High", kept: 4, replay: 0.5))
        #expect(PixelDiff.differingPixels(kept, changed, tolerance: 0.05) > 1_000, "kept and changed are different colours")
        let tick = PixelDiff.differingPixels(kept, ticked, tolerance: 0.05)
        #expect(tick > 0, "the replay tick isn't drawn")
        #expect(tick < 400, "the replay tick is a thin mark, not a recolour: \(tick) pixels")
    }

    /// The whole sheet, with a change list longer than four rows.
    @Test(.machinePinned(.pixelSampling)) func theSheetRendersEveryPanel() throws {
        var records = (0..<6).map { Self.record(.kept, name: "kept-\($0).pdf") }
        records += [
            Self.record(.changed, confidence: .medium, offered: "Health/Medical/India", landed: "Finance/Shipments", name: "FedEx invoice.pdf", daysAgo: 2),
            Self.record(.changed, confidence: .low, offered: "Health/Medical/India", landed: "Finance/Shipments", name: "Courier receipt.pdf", daysAgo: 3),
            Self.record(.changed, confidence: .medium, offered: "Immigration/Reference", landed: "Work/Reports", name: "Duplicate Files Report.md", daysAgo: 4),
            Self.record(.changed, confidence: .low, offered: "Travel/2026", landed: "Immigration/Visa", name: "Visa appointment.pdf", daysAgo: 5),
            Self.record(.changed, confidence: .high, offered: "Finance/Insurance", landed: "Vehicles/Insurance", name: "Car insurance.pdf", daysAgo: 6),
            Self.record(.deeper, confidence: .medium, offered: "Purchases", landed: "Purchases/US Mint", name: "Mint Order.pdf", daysAgo: 7),
        ]
        let size = CGSize(width: 680, height: 720)
        let session = LensWorkspaceSession()
        let manager = FileSyncManager()
        let full = try Self.rendered(FilingScorecardSheet(store: Self.store(records), session: session,
                                                          syncManager: manager, accent: .blue), size)
        let empty = try Self.rendered(FilingScorecardSheet(store: Self.store([]), session: session,
                                                           syncManager: manager, accent: .blue), size)
        #expect(PixelDiff.differingPixels(full, empty, tolerance: 0.05) > 20_000)
    }
}

/// Hide swaps the line for the notice, and the notice stays until To File is left: the slot's
/// `onDisappear` fires when the slot goes, not when only its content changes.
@Suite(.serialized) @MainActor struct FilingScorecardHideTests {
    final class State: ObservableObject {
        @Published var shown = true
        @Published var justHidden = false
        @Published var mounted = true
    }

    struct Host: View {
        @ObservedObject var state: State
        let store: FilingScorecardStore
        var body: some View {
            VStack {
                if state.mounted {
                    FilingScorecardSlot(store: store, accent: .blue, inset: 8,
                                        shown: $state.shown, justHidden: $state.justHidden, onDetails: {})
                }
            }
            .frame(width: 520, height: 60)
        }
    }

    static func settle(_ host: NSView) {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @Test func theNoticeOutlivesTheSwapAndGoesWithToFile() {
        let state = State()
        let host = NSHostingView(rootView: Host(state: state, store: FilingScorecardStore(fileURL: nil)))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        Self.settle(host)

        // What the line's Hide does.
        state.shown = false
        state.justHidden = true
        Self.settle(host)
        #expect(state.justHidden, "the notice was cleared the moment it replaced the line")

        // Leaving To File takes the slot away, and the notice with it.
        state.mounted = false
        Self.settle(host)
        #expect(!state.justHidden)
        window.contentView = nil
    }
}
