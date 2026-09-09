import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// **What Organize forgot on every workspace switch, and the reset that has to keep working now
/// that it does not.**
///
/// `LensWorkspaceView` is mounted by `bottomPaneView`, inside one arm of `ContentView`'s layout
/// switch. Leaving Organize destroys that arm, so everything the reader had set went back to its
/// default: the match filter to All, the parked query gone, the unfolded sections re-folded, "freed
/// this session" to zero, the filed/dismissed flags to false. The rail item and the scope survived —
/// they are `@AppStorage` — which is what made it read as arbitrary rather than as a reset.
///
/// The state lives in ``LensWorkspaceSession`` now, held by `ContentView`, which is mounted once for
/// the window. **That makes the scan-start resets load-bearing in a way they were not.** They always
/// ran, but a fresh mount used to clear this state anyway, so an omission from `DuplicateScanReset`
/// had a second net under it. There is no second net now: a narrowing that survives its scan is
/// shown against results it was never aimed at, which is the exact defect that list was written for.
@MainActor
@Suite struct OrganizeSessionPersistenceTests {

    // MARK: The session holds what the reader set

    /// The round trip, as a value: state written into a session is still there in the session a
    /// later mount is handed. This is the whole fix — the view being rebuilt no longer takes the
    /// narrowing with it, because the narrowing was never in the view.
    @Test func aSessionKeepsEveryNarrowingAcrossAMount() {
        let session = LensWorkspaceSession()
        session.filter = .versions
        session.searchQueries[.duplicates] = "kind:pdf >5mb"
        session.searchExpandedLenses.insert(.duplicates)
        session.unfoldedSections.insert(.identical)
        session.reclaim.credit(4_096)
        session.filedThisSession = true
        session.dismissedThisSession = true

        // What a workspace switch does: the view goes, the session does not.
        let survivor = LensWorkspaceView.startingSession(session, seed: [:])

        #expect(survivor === session, "a host session was replaced rather than reused")
        #expect(survivor.filter == .versions)
        #expect(survivor.searchQueries[.duplicates] == "kind:pdf >5mb")
        #expect(survivor.searchExpandedLenses.contains(.duplicates))
        #expect(survivor.unfoldedSections.contains(.identical))
        #expect(survivor.reclaim.totalBytes == 4_096)
        #expect(survivor.filedThisSession)
        #expect(survivor.dismissedThisSession)
    }

    /// A caller with no session of its own gets a fresh one — which is what every test that mounts
    /// this view to ask about something else relies on, and is exactly the behaviour the state had
    /// as `@State`.
    @Test func noHostSessionMeansPerMountState() {
        let first = LensWorkspaceView.startingSession(nil, seed: [:])
        first.filter = .versions
        let second = LensWorkspaceView.startingSession(nil, seed: [:])

        #expect(first !== second)
        #expect(second.filter == .all, "an unhosted mount inherited another mount's narrowing")
    }

    // MARK: The seed

    /// `initialSearchQueries` is the one way into a live query without typing, and SwiftUI cannot be
    /// driven from a unit test — so it is what makes anything depending on a query testable at all.
    @Test func aSeededQueryReachesTheSession() {
        let session = LensWorkspaceView.startingSession(nil, seed: [.duplicates: "invoice"])
        #expect(session.searchQueries[.duplicates] == "invoice")
    }

    /// **An empty seed may not clear a live query**, which is the failure mode of applying the seed
    /// anywhere other than on first mount. The app passes no seed, so a seed written on every init
    /// would wipe the reader's parked query the next time anything published — and something
    /// publishes several times a second while a scan runs.
    @Test func anEmptySeedLeavesAParkedQueryAlone() {
        let session = LensWorkspaceSession()
        session.searchQueries[.duplicates] = "kind:pdf"

        let survivor = LensWorkspaceView.startingSession(session, seed: [:])

        #expect(survivor.searchQueries[.duplicates] == "kind:pdf",
                "the app's empty seed cleared a query the reader had typed")
    }

    // MARK: The resets, which now have nothing under them

    /// A new scan retires the previous scan's narrowing even when the session outlives the view.
    ///
    /// Driven through the same `inout` call the view makes, because the interesting question is
    /// whether the reset still reaches state that is no longer `@State` — computed forwarders pass
    /// `inout` by get-modify-set, and a forwarder that read the session but wrote somewhere else
    /// would compile and silently drop the reset.
    @Test func aFreshScanRetiresTheNarrowingHeldInTheSession() {
        let session = LensWorkspaceSession()
        session.filter = .versions
        session.searchQueries[.duplicates] = "kind:pdf"
        session.reclaim.credit(8_192)

        DuplicateScanReset.duplicatesScanStarted(filter: &session.filter,
                                                 searchQuery: &session.searchQueries[.duplicates, default: ""],
                                                 reclaim: &session.reclaim)

        #expect(session.filter == .all,
                "a filter picked against the previous results survived into a new scan")
        #expect(session.searchQueries[.duplicates]?.isEmpty ?? true)
        #expect(session.reclaim.totalBytes == 0,
                "\"freed this session\" carried a previous scan's total")
    }

    /// **The Organize-side scan-start reset still names every flag it has to.**
    ///
    /// Scanned rather than driven: those assignments live in `.onChange(of: isSuggestingFiles)`
    /// inside a SwiftUI body, which a unit test cannot fire. What can be checked is that the handler
    /// still clears each one — and that matters more than it did, because until now a fresh mount
    /// cleared them regardless of what the handler said. An omission from that block used to be
    /// invisible; it is now a stale "All filed" over a scan that filed nothing.
    ///
    /// The positive control is the `#require`: if the handler cannot be found at all, this fails
    /// with that rather than passing on an empty search.
    @Test func theScanStartHandlerStillRetiresEveryOrganizeSessionFlag() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read LensWorkspaceView.swift — this scan would be vacuous")
        let marker = try #require(source.range(of: ".onChange(of: syncManager.isSuggestingFiles)"),
                                  "the filing scan-start handler is gone — nothing retires the session flags")
        let handler = String(source[marker.lowerBound...].prefix(1_200))

        for cleared in ["filedThisSession = false",
                        "dismissedThisSession = false",
                        "pendingRememberPrompt = nil",
                        "pendingRuleOffer = nil"] {
            #expect(handler.contains(cleared),
                    "a fresh filing scan no longer clears `\(cleared)` — and the mount that used to hide that is gone")
        }
    }
}
