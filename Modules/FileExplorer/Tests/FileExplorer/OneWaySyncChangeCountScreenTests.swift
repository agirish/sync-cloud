import AppKit
import Design
import Foundation
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// The change count on screen: the pill's rung for what changed since the last sync, its words,
/// its colour, and the controller handing its record to the count. Scratch parents; nothing syncs.
@MainActor
@Suite struct OneWaySyncChangeCountScreenTests {
    typealias Scratch = OneWaySyncControllerTests.Scratch
    static let lastSync: Int64 = 1_789_990_000

    func controller(_ scratch: Scratch, state: OneWaySyncSavedState = OneWaySyncSavedState(lastSyncAt: lastSync))
        -> (OneWaySyncController, ActivityCenter) {
        let center = ActivityCenter()
        let controller = OneWaySyncController(store: nil, center: center, cloudApps: CloudAppMonitor(), refusal: .testRunner)
        controller.adopt(scratch.record, state: state)
        return (controller, center)
    }

    /// The scratch record holds Legal/Will.pdf, which isn't on disk: a removal the watcher reports
    /// is a change against that record.
    func noteRemoval(_ controller: OneWaySyncController, _ scratch: Scratch, id: UInt64 = 10) {
        let path = scratch.iCloud.appendingPathComponent("Legal/Will.pdf").path
        controller.changes.note(FolderWatchBatch(events: [FolderWatchEvent(
            id: id, root: scratch.iCloud.appendingPathComponent("Legal").path, path: path, realPath: path, change: [.removed, .isFile])]))
        controller.refreshChangeTally()
    }

    /// The call site: the record the controller holds is what the count judges against. Without it
    /// the count has nothing to compare with and counts nothing.
    @Test func theControllersRecordIsWhatTheCountJudgesAgainst() throws {
        let scratch = try Scratch()
        let (controller, _) = controller(scratch)
        noteRemoval(controller, scratch)
        #expect(controller.changeTally == .init(count: 1))
        #expect(controller.ladder == .changes(1, since: Date(timeIntervalSince1970: TimeInterval(Self.lastSync))))
    }

    /// A record the controller takes on reaches the pill at once: a folder unticked in Choose
    /// Folders takes its count with it, with no batch needed to show it.
    @Test func aNewRecordReachesThePillAtOnce() throws {
        let scratch = try Scratch()
        let (controller, _) = controller(scratch)
        noteRemoval(controller, scratch)
        #expect(controller.changeTally.count == 1)
        var record = scratch.record
        record.syncedFolders = [OneWaySyncFolderRecord(key: 7, iCloudPath: "Work", dropboxPath: "Work", firstRunCompleted: true)]
        controller.adopt(record, state: OneWaySyncSavedState(lastSyncAt: Self.lastSync))
        #expect(controller.changeTally == .init())
        #expect(controller.ladder == .upToDate(asOf: Date(timeIntervalSince1970: TimeInterval(Self.lastSync)), skipped: 0))
    }

    /// The ladder, first that applies: what needs you and Pause outrank the count, which outranks
    /// "Synced at"; unknown reads as changes that may be waiting; never synced stays "not yet".
    @Test func theCountSitsBelowPauseAndAboveSynced() throws {
        let scratch = try Scratch()
        let since = Date(timeIntervalSince1970: TimeInterval(Self.lastSync))
        let (controller, center) = controller(scratch)
        #expect(controller.ladder == .upToDate(asOf: since, skipped: 0))
        noteRemoval(controller, scratch)
        #expect(controller.ladder == .changes(1, since: since))
        controller.adopt(scratch.record, state: OneWaySyncSavedState(pausedSince: Self.lastSync + 60, lastSyncAt: Self.lastSync))
        #expect(controller.ladder == .paused(since: since.addingTimeInterval(60)), "Pause leaves the count but shows Paused")
        #expect(controller.changeTally.count == 1)
        controller.adopt(scratch.record, state: OneWaySyncSavedState(lastSyncAt: Self.lastSync))
        OneWaySyncScreensTests.waiting(center)
        #expect(controller.ladder == .needsYou(1))
        center.clearOneWaySync(["ows:file:Legal/Will.pdf"])
        controller.changes.note(FolderWatchBatch(rescans: [FolderWatchRescan(
            root: scratch.iCloud.appendingPathComponent("Legal").path, path: scratch.iCloud.appendingPathComponent("Legal").path,
            reason: .historyLost, id: 20)]))
        controller.refreshChangeTally()
        #expect(controller.ladder == .changesMayBeWaiting(since: since))
        controller.adopt(scratch.record, state: OneWaySyncSavedState())
        #expect(controller.ladder == .notYetSynced)
    }

    @Test func thePillSaysHowManyAndSince() throws {
        // Today whatever the hour, so a run just past midnight still means today.
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(1)
        let clock = today.formatted(date: .omitted, time: .shortened)
        #expect(OneWaySyncStatusPill.title(.changes(1, since: today)) == "1 change since \(clock) · Sync Now")
        #expect(OneWaySyncStatusPill.title(.changes(1_204, since: today)) == "\(1_204.formatted()) changes since \(clock) · Sync Now")
        let earlier = try #require(Calendar.current.date(byAdding: .day, value: -3, to: Date()))
        #expect(OneWaySyncStatusPill.title(.changes(3, since: earlier))
                == "3 changes since \(earlier.formatted(.dateTime.day().month(.abbreviated))) · Sync Now")
        #expect(OneWaySyncStatusPill.title(.changesMayBeWaiting(since: today)) == "Changes may be waiting · Sync Now")
        // The overview's and Settings' line says the same without the button.
        #expect(OneWaySyncLadder.changes(2, since: today).title() == "2 changes since \(clock)")
    }

    // MARK: Colour

    /// Renders the pill under `hue` and returns its bitmap. The window background stops a
    /// comparison against a borderless window's black.
    func render(_ controller: OneWaySyncController, _ center: ActivityCenter, hue: LiquidGlassHue) throws -> NSBitmapImageRep {
        let defaults = try #require(UserDefaults(suiteName: "OneWayPill-\(UUID().uuidString)"))
        defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)
        let size = CGSize(width: 320, height: 30)
        let subject = OneWaySyncStatusPill(controller: controller, center: center, onSetUp: {})
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<min(a.pixelsWide, b.pixelsWide) {
            for y in 0..<min(a.pixelsHigh, b.pixelsHigh) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
        }
        return count
    }

    /// The count draws in the app's accent, so Coral and Green differ; "Synced at" keeps its
    /// green whatever the accent — the control that shows the hue reaches the pill at all.
    @Test func theCountDrawsInTheAccent() throws {
        let scratch = try Scratch()
        let (controller, center) = controller(scratch)
        let syncedCoral = try render(controller, center, hue: .coral), syncedGreen = try render(controller, center, hue: .green)
        #expect(differingPixels(syncedCoral, syncedGreen) == 0, "Synced at took the accent")
        noteRemoval(controller, scratch)
        let coral = try render(controller, center, hue: .coral), green = try render(controller, center, hue: .green)
        #expect(differingPixels(coral, syncedCoral) > 100, "the pill didn't change when changes came in")
        #expect(differingPixels(coral, green) > 100, "the count's pill isn't in the accent")
    }
}
